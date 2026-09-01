local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Keep database, network, JSON, and dialog modules out of the plugin's startup
-- footprint. They are loaded only when the corresponding feature is used.
local DictQuickLookup, InfoMessage, InputDialog, JSON, NetworkMgr, SQ3
local TextBoxWidget
local ltn12, socket, http, socketutil, url

local function sqliteModule()
    if not SQ3 then SQ3 = require("lua-ljsqlite3/init") end
    return SQ3
end

local function openDatabase(path)
    return sqliteModule().open(path, "ro")
end

local function newInfoMessage(options)
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    return InfoMessage:new(options)
end

local function showLookupProgress()
    local progress = newInfoMessage{
        text = _("Looking up pronunciation…"),
        dismissable = false,
        show_icon = false,
    }
    UIManager:show(progress)
    -- Make the message visible before database, G2P, or HTTP work blocks the
    -- event loop. Guard both APIs for compatibility with older KOReader builds.
    if type(UIManager.forceRePaint) == "function" then
        UIManager:forceRePaint()
    end
    return progress
end

local function closeLookupProgress(progress)
    if progress then UIManager:close(progress) end
end

local function showLookupMessage(progress, text)
    closeLookupProgress(progress)
    UIManager:show(newInfoMessage{ text = text })
end

local function afterLookupProgress(callback)
    if type(UIManager.nextTick) == "function" then
        UIManager:nextTick(callback)
    else
        callback()
    end
end

local function runLookupSafely(word, progress, callback)
    local ok, error_message = pcall(callback)
    if ok then return end
    logger.err("Pronunciation lookup failed:", error_message)
    showLookupMessage(progress,
        word .. "\n\n" .. _("Pronunciation lookup failed. Please try again."))
end

local function loadOnlineModules()
    if http then return end
    JSON = require("json")
    ltn12 = require("ltn12")
    socket = require("socket")
    http = require("socket.http")
    socketutil = require("socketutil")
    url = require("socket.url")
end

local PLUGIN_VERSION = "0.5.0"
local CACHE_VERSION = 5
local GENERATOR_VERSION = 2
local SOURCED_CACHE_LIMIT = 256
local GENERATED_CACHE_LIMIT = 128
local GENERATED_CACHE_PREFIX = "generator:" .. GENERATOR_VERSION .. "|"

local Pronunciation = WidgetContainer:extend{
    name = "pronunciation",
    is_doc_only = true,
}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local LATIN_LOWERCASE = {
    ["À"] = "à", ["Á"] = "á", ["Â"] = "â", ["Ã"] = "ã",
    ["Ä"] = "ä", ["Å"] = "å", ["Æ"] = "æ", ["Ç"] = "ç",
    ["È"] = "è", ["É"] = "é", ["Ê"] = "ê", ["Ë"] = "ë",
    ["Ì"] = "ì", ["Í"] = "í", ["Î"] = "î", ["Ï"] = "ï",
    ["Ñ"] = "ñ", ["Ò"] = "ò", ["Ó"] = "ó", ["Ô"] = "ô",
    ["Õ"] = "õ", ["Ö"] = "ö", ["Ø"] = "ø", ["Œ"] = "œ",
    ["Ù"] = "ù", ["Ú"] = "ú", ["Û"] = "û", ["Ü"] = "ü",
    ["Ý"] = "ý", ["Ÿ"] = "ÿ",
}

local function normalizeWord(word)
    word = trim(word):lower()
    if word:find("[\128-\255]") then
        for upper, lower in pairs(LATIN_LOWERCASE) do
            word = word:gsub(upper, lower)
        end
    end
    word = word:gsub("‘", "'"):gsub("’", "'")
        :gsub("^“", ""):gsub("^”", ""):gsub("^«", ""):gsub("^»", "")
        :gsub("“$", ""):gsub("”$", ""):gsub("«$", ""):gsub("»$", "")
    return word:gsub("^[%p%s]+", ""):gsub("[%p%s]+$", "")
end

-- KOReader keeps the originally queried text in `word` and the currently
-- displayed dictionary headword in `lookupword`. Very old/custom builds may
-- expose only the latter, so retain it strictly as a compatibility fallback.
local function popupQueryWord(dict_popup)
    if type(dict_popup) ~= "table" then return nil end
    local query_word = trim(dict_popup.word)
    if query_word ~= "" then return query_word end
    return trim(dict_popup.lookupword)
end

local function stripIpaWrappers(ipa)
    local core = trim(ipa)
    local first = core:sub(1, 1)
    if first == "/" or first == "[" then
        core = core:sub(2)
    end
    local last = core:sub(-1)
    if last == "/" or last == "]" then
        core = core:sub(1, -2)
    end
    return trim(core)
end

local function wrapIpa(ipa)
    local core = stripIpaWrappers(ipa)
    if core == "" then return nil end
    return "/" .. core .. "/"
end

-- Ordered longest-first so diphthongs and affricates remain single phones.
local IPA_PHONE_SPECS = {
    { "t͡ʃ", "ch", false }, { "d͡ʒ", "j", false },
    { "tʃ", "ch", false }, { "dʒ", "j", false },
    { "aɪ", "eye", true }, { "aʊ", "ow", true },
    { "eɪ", "ay", true }, { "oʊ", "oh", true },
    { "əʊ", "oh", true }, { "ɔɪ", "oy", true },
    { "ɪə", "ear", true }, { "eə", "air", true },
    { "ɛə", "air", true }, { "ʊə", "oor", true },
    { "iː", "ee", true }, { "uː", "oo", true },
    { "ɑː", "ah", true }, { "ɔː", "aw", true },
    { "ɜː", "er", true }, { "ɝː", "er", true },
    { "n̩", "uhn", true }, { "l̩", "uhl", true },
    { "m̩", "uhm", true },
    { "i", "ee", true }, { "ɪ", "ih", true },
    { "e", "eh", true }, { "ɛ", "eh", true },
    { "æ", "a", true }, { "a", "ah", true },
    { "ə", "uh", true }, { "ɐ", "uh", true },
    { "ʌ", "uh", true }, { "ɜ", "er", true },
    { "ɝ", "er", true }, { "ɚ", "er", true },
    { "ɑ", "ah", true }, { "ɒ", "ah", true },
    { "ɔ", "aw", true }, { "o", "oh", true },
    { "ʊ", "uu", true }, { "u", "oo", true },
    { "ɵ", "uh", true }, { "ɞ", "ur", true },
    { "p", "p", false }, { "b", "b", false },
    { "t", "t", false }, { "d", "d", false },
    { "k", "k", false }, { "ɡ", "g", false }, { "g", "g", false },
    { "f", "f", false }, { "v", "v", false },
    { "θ", "th", false }, { "ð", "th", false },
    { "s", "s", false }, { "z", "z", false },
    { "ʃ", "sh", false }, { "ʒ", "zh", false },
    { "h", "h", false }, { "x", "kh", false },
    { "m", "m", false }, { "n", "n", false },
    { "ɲ", "ny", false },
    { "ŋ", "ng", false },
    { "l", "l", false }, { "ɫ", "l", false }, { "ʎ", "ly", false },
    { "ɹ", "r", false }, { "r", "r", false },
    { "ɻ", "r", false }, { "ɾ", "r", false }, { "ʁ", "r", false },
    { "j", "y", false }, { "w", "w", false },
    { "ɟ", "gy", false }, { "β", "v", false }, { "ɣ", "gh", false },
    { "ʍ", "hw", false }, { "ʔ", "", false },
}

local IPA_ONSETS = {
    ["pr"] = true, ["pl"] = true, ["pj"] = true,
    ["br"] = true, ["bl"] = true, ["bj"] = true,
    ["tr"] = true, ["tw"] = true, ["tj"] = true,
    ["dr"] = true, ["dw"] = true, ["dj"] = true,
    ["kr"] = true, ["kl"] = true, ["kw"] = true, ["kj"] = true,
    ["ɡr"] = true, ["ɡl"] = true, ["ɡw"] = true, ["ɡj"] = true,
    ["gr"] = true, ["gl"] = true, ["gw"] = true, ["gj"] = true,
    ["fr"] = true, ["fl"] = true, ["fj"] = true,
    ["vr"] = true, ["vj"] = true, ["θr"] = true,
    ["ʃr"] = true, ["tʃr"] = true, ["dʒr"] = true,
    ["sp"] = true, ["st"] = true, ["sk"] = true,
    ["sm"] = true, ["sn"] = true, ["sl"] = true, ["sw"] = true,
    ["spr"] = true, ["spl"] = true, ["str"] = true,
    ["skr"] = true, ["skw"] = true,
}

local IPA_INVALID_SINGLE_ONSETS = { ["ŋ"] = true }
local IPA_LAX_VOWELS = {
    ["ɪ"] = true, ["ɛ"] = true, ["æ"] = true,
    ["ə"] = true, ["ʌ"] = true, ["ʊ"] = true,
}

local function nextUtf8Character(text, position)
    local tail = text:sub(position)
    return tail:match("^([%z\1-\127\194-\244][\128-\191]*)")
end

local IPA_PHONE_SPECS_BY_FIRST = {}
for _, spec in ipairs(IPA_PHONE_SPECS) do
    local first = nextUtf8Character(spec[1], 1)
    local bucket = IPA_PHONE_SPECS_BY_FIRST[first]
    if not bucket then
        bucket = {}
        IPA_PHONE_SPECS_BY_FIRST[first] = bucket
    end
    bucket[#bucket + 1] = spec
end

local function tokenizeIpa(ipa)
    local core = stripIpaWrappers(ipa):gsub("͡", "")
    local phones = {}
    local position = 1
    local pending_stress
    local pending_break = false

    while position <= #core do
        local rest = core:sub(position)
        if rest:sub(1, #"ˈ") == "ˈ" then
            pending_stress = 1
            position = position + #"ˈ"
        elseif rest:sub(1, #"ˌ") == "ˌ" then
            pending_stress = 2
            position = position + #"ˌ"
        else
            local matched
            local first_character = nextUtf8Character(rest, 1)
            for _, spec in ipairs(IPA_PHONE_SPECS_BY_FIRST[first_character] or {}) do
                if rest:sub(1, #spec[1]) == spec[1] then
                    matched = spec
                    break
                end
            end
            if matched then
                local phone = {
                    symbol = matched[1]:gsub("͡", ""),
                    readable = matched[2],
                    vowel = matched[3],
                    break_before = pending_break,
                }
                pending_break = false
                if phone.vowel and pending_stress then
                    phone.stress = pending_stress
                    pending_stress = nil
                end
                phones[#phones + 1] = phone
                position = position + #matched[1]
            else
                local character = first_character
                if not character then break end
                if character == "." or character == "-" or character == " " then
                    pending_break = true
                end
                -- Ignore punctuation, optional-phone markers, length marks and diacritics.
                position = position + #character
            end
        end
    end
    return phones
end

local function onsetKey(phones, first, last)
    local parts = {}
    for i = first, last do
        parts[#parts + 1] = phones[i].symbol
    end
    return table.concat(parts)
end

local function chooseIpaOnsetLength(phones, previous_vowel, vowel_index)
    local cluster_length = vowel_index - previous_vowel - 1
    if cluster_length <= 0 then return 0 end

    local maximum = math.min(3, cluster_length)
    local previous = phones[previous_vowel]
    if previous.stress == 1 and IPA_LAX_VOWELS[previous.symbol] then
        maximum = math.min(maximum, cluster_length - 1)
    end

    for length = maximum, 1, -1 do
        local first = vowel_index - length
        if length == 1 then
            if not IPA_INVALID_SINGLE_ONSETS[phones[first].symbol] then
                return 1
            end
        elseif IPA_ONSETS[onsetKey(phones, first, vowel_index - 1)] then
            return length
        end
    end
    return 0
end

local function readableFromIpa(ipa)
    local phones = tokenizeIpa(ipa)
    if #phones == 0 then return nil end

    local vowels = {}
    for i, phone in ipairs(phones) do
        if phone.vowel then vowels[#vowels + 1] = i end
    end
    if #vowels == 0 then return nil end

    local starts = { 1 }
    for v = 2, #vowels do
        local previous_vowel = vowels[v - 1]
        local vowel_index = vowels[v]
        local explicit_start
        for i = previous_vowel + 1, vowel_index do
            if phones[i].break_before then explicit_start = i end
        end
        starts[#starts + 1] = explicit_start
            or (vowel_index - chooseIpaOnsetLength(phones, previous_vowel, vowel_index))
    end

    local syllables = {}
    for s = 1, #starts do
        local first = starts[s]
        local last = (starts[s + 1] or (#phones + 1)) - 1
        local spelling = {}
        local stress
        for i = first, last do
            local readable = phones[i].readable
            if phones[i].symbol == "ɪ" and phones[i].stress == 1 then
                readable = "i"
            end
            spelling[#spelling + 1] = readable
            if phones[i].stress then stress = phones[i].stress end
        end
        local text = table.concat(spelling)
        if stress == 1 or (#starts == 1 and not stress) then
            text = text:upper()
        end
        if text ~= "" then syllables[#syllables + 1] = text end
    end
    if #syllables == 0 then return nil end
    return table.concat(syllables, "-")
end

function Pronunciation:readableFromIpa(ipa)
    return readableFromIpa(ipa)
end

local function ensureReadable(result)
    if result and (not result.simple or result.simple == "") and result.ipa then
        result.simple = readableFromIpa(result.ipa)
        result.simple_approx = result.simple ~= nil
    end
    return result
end

local function ensureReadables(results)
    for _, result in ipairs(results or {}) do ensureReadable(result) end
    return results
end

local normalizeOnlineIpa

local LANGUAGE_DEFINITIONS = {
    catalan = { code = "ca", name = "Catalan" },
    dutch = { code = "nl", name = "Dutch" },
    english = { code = "en", name = "English", region = "US" },
    french = { code = "fr", name = "French" },
    german = { code = "de", name = "German" },
    italian = { code = "it", name = "Italian" },
    latin = { code = "la", name = "Latin" },
    portuguese = { code = "pt", name = "Portuguese" },
    spanish = { code = "es", name = "Spanish" },
    welsh = { code = "cy", name = "Welsh" },
}

local LANGUAGE_BY_CODE = {}
for _, definition in pairs(LANGUAGE_DEFINITIONS) do
    LANGUAGE_BY_CODE[definition.code] = definition
end

local LANGUAGE_CODE_ALIASES = {
    cat = "ca", cym = "cy", dut = "nl", nld = "nl", eng = "en",
    fra = "fr", fre = "fr", deu = "de",
    ger = "de", ita = "it", lat = "la", por = "pt", spa = "es",
}

local function normalizeLanguageKey(value)
    if type(value) ~= "string" then return "" end
    local key = trim(value):lower():gsub("_", "-")
    key = trim(key:match("^([^,;]+)") or key)
    return key
end

local function languageDefinition(name, code)
    local function resolve(value)
        if value and value ~= "" then
            local key = normalizeLanguageKey(value)
            local definition = LANGUAGE_DEFINITIONS[key]
                or LANGUAGE_BY_CODE[LANGUAGE_CODE_ALIASES[key] or key]
            if definition then return definition end

            local base = key:match("^([a-z][a-z][a-z]?)%-")
            if base then
                definition = LANGUAGE_BY_CODE[LANGUAGE_CODE_ALIASES[base] or base]
                if definition then return definition end
            end
        end
    end
    return resolve(code) or resolve(name)
end

local function mergeLanguageHints(...)
    local merged = {}
    local seen = {}
    for index = 1, select("#", ...) do
        for _, hint in ipairs(select(index, ...) or {}) do
            local definition = languageDefinition(hint.name, hint.code)
            if definition and not seen[definition.code] then
                seen[definition.code] = true
                merged[#merged + 1] = {
                    code = definition.code,
                    name = definition.name,
                    region = definition.region,
                    source = hint.source,
                }
            end
        end
    end
    return merged
end

local GENERATION_LANGUAGE_ORDER = { "english" }
local SELECTABLE_GENERATION_LANGUAGES = { en = true }

local ARPABET_IPA = {
    AA = "ɑ", AE = "æ", AO = "ɔ", AW = "aʊ", AY = "aɪ",
    EH = "ɛ", EY = "eɪ", IH = "ɪ", IY = "i", OW = "oʊ",
    OY = "ɔɪ", UH = "ʊ", UW = "u",
    B = "b", CH = "tʃ", D = "d", DH = "ð", F = "f",
    G = "ɡ", HH = "h", JH = "dʒ", K = "k", L = "l",
    M = "m", N = "n", NG = "ŋ", P = "p", R = "ɹ",
    S = "s", SH = "ʃ", T = "t", TH = "θ", V = "v",
    W = "w", Y = "j", Z = "z", ZH = "ʒ",
}

local ARPABET_VOWELS = {
    AA = true, AE = true, AH = true, AO = true, AW = true,
    AY = true, EH = true, ER = true, EY = true, IH = true,
    IY = true, OW = true, OY = true, UH = true, UW = true,
}

local function arpabetBase(phone)
    return phone:gsub("[012]$", "")
end

local function arpabetPhonesToIpa(arpabet)
    local phones = {}
    local vowels = {}
    for _, phone in ipairs(arpabet) do
        local base = arpabetBase(phone)
        local phone_stress = tonumber(phone:match("([012])$"))
        local vowel = ARPABET_VOWELS[base] == true
        local symbol
        if base == "AH" then
            symbol = phone_stress == 0 and "ə" or "ʌ"
        elseif base == "ER" then
            symbol = phone_stress == 0 and "ɚ" or "ɝ"
        else
            symbol = ARPABET_IPA[base]
        end
        if not symbol then return nil end
        phones[#phones + 1] = {
            symbol = symbol,
            vowel = vowel,
            stress = phone_stress,
        }
        if vowel then vowels[#vowels + 1] = #phones end
    end
    if #phones == 0 then return nil end

    local starts = {}
    if #vowels > 0 then
        starts[1] = 1
        for index = 2, #vowels do
            local previous_vowel = vowels[index - 1]
            local vowel_index = vowels[index]
            starts[index] = vowel_index
                - chooseIpaOnsetLength(phones, previous_vowel, vowel_index)
        end
    end

    local stress_at = {}
    for index, start in ipairs(starts) do
        local stress = phones[vowels[index]].stress
        if stress == 1 then stress_at[start] = "ˈ"
        elseif stress == 2 then stress_at[start] = "ˌ" end
    end

    local output = {}
    for index, phone in ipairs(phones) do
        if stress_at[index] then output[#output + 1] = stress_at[index] end
        output[#output + 1] = phone.symbol
    end
    return "/" .. table.concat(output) .. "/"
end

local function readLittleEndian16(data, position)
    local low, high = data:byte(position, position + 1)
    if not low or not high then return nil end
    return low + high * 256
end

local function readLittleEndian24(data, position)
    local low, middle, high = data:byte(position, position + 2)
    if not low or not middle or not high then return nil end
    return low + middle * 256 + high * 65536
end

local function readLittleEndian32(data, position)
    local low, middle_low, middle_high, high = data:byte(position, position + 3)
    if not low or not middle_low or not middle_high or not high then return nil end
    return low + middle_low * 256 + middle_high * 65536 + high * 16777216
end

local function readSignedLittleEndian16(data, position)
    local value = readLittleEndian16(data, position)
    if not value then return nil end
    return value >= 32768 and value - 65536 or value
end

local G2P_HEADER_SIZE = 30
local G2P_STATE_RECORD_SIZE = 2
local G2P_ARC_RECORD_SIZE = 6
local G2P_RANK_RECORD_SIZE = 3
local G2P_INFINITE_FINAL = 65535
local G2P_PACKED_LIMIT = 16777216
local G2P_STATE_OFFSET_BLOCK = 256
local G2P_FINAL_RANK_BLOCK = 256
local G2P_MAX_WORD_BYTES = 64
local G2P_MAX_RELAXATIONS = 500000

local G2P_POPCOUNT = {}
for value = 0, 255 do
    local count = 0
    local remaining = value
    while remaining > 0 do
        count = count + remaining % 2
        remaining = math.floor(remaining / 2)
    end
    G2P_POPCOUNT[value] = count
end

-- Portable US-English inference from Montreal Forced Aligner's weighted
-- Pynini G2P graph. The bundled graph is repacked into fixed-width records;
-- this loader retains only its compact index and reads arc blocks on demand.
function Pronunciation:_loadEnglishG2pModel()
    if self.english_g2p_model ~= nil then
        return self.english_g2p_model or nil
    end
    if not self.path then
        self.english_g2p_model = false
        return nil
    end

    local model_path = self.path .. "/data/mfa_english_g2p.bin"
    local handle = io.open(model_path, "rb")
    if not handle then
        self.english_g2p_model = false
        return nil
    end

    local header = handle:read(G2P_HEADER_SIZE)
    if not header or #header ~= G2P_HEADER_SIZE
            or header:sub(1, 8) ~= "KPG2P3\0\0" then
        handle:close()
        logger.warn("Pronunciation: invalid bundled English G2P model header")
        self.english_g2p_model = false
        return nil
    end

    local state_count = readLittleEndian32(header, 9)
    local arc_count = readLittleEndian32(header, 13)
    local start_state = readLittleEndian32(header, 17)
    local weight_scale = readLittleEndian16(header, 21)
    local phone_count = header:byte(23)
    local state_record_size = header:byte(24)
    local arc_record_size = header:byte(25)
    local final_count = readLittleEndian32(header, 27)
    if not state_count or state_count == 0 or not arc_count or arc_count == 0
            or state_count >= G2P_PACKED_LIMIT
            or arc_count >= G2P_PACKED_LIMIT
            or not start_state or start_state >= state_count
            or not weight_scale or weight_scale == 0 or not phone_count
            or phone_count == 0
            or state_record_size ~= G2P_STATE_RECORD_SIZE
            or arc_record_size ~= G2P_ARC_RECORD_SIZE
            or header:byte(26) ~= 0
            or not final_count or final_count > state_count then
        handle:close()
        logger.warn("Pronunciation: unsupported bundled English G2P model")
        self.english_g2p_model = false
        return nil
    end

    local phone_table = {}
    for index = 1, phone_count do
        local length_data = handle:read(1)
        local length = length_data and length_data:byte(1)
        local phone = length and handle:read(length)
        if not phone or #phone ~= length or not phone:match("^[A-Z]+[012]?$") then
            handle:close()
            logger.warn("Pronunciation: invalid English G2P phone table")
            self.english_g2p_model = false
            return nil
        end
        phone_table[index] = phone
    end

    local state_offset_base_count = math.floor(
        state_count / G2P_STATE_OFFSET_BLOCK) + 1
    local state_offset_bases = handle:read(
        state_offset_base_count * 3)
    local state_offset_deltas = handle:read(
        (state_count + 1) * state_record_size)
    local final_bitmap_size = math.floor((state_count + 7) / 8)
    local final_bitmap = handle:read(final_bitmap_size)
    local final_rank_count = math.floor(
        (state_count + G2P_FINAL_RANK_BLOCK - 1) / G2P_FINAL_RANK_BLOCK) + 1
    local final_ranks = handle:read(final_rank_count * G2P_RANK_RECORD_SIZE)
    local final_weights = handle:read(final_count * 2)
    local arc_table_offset = handle:seek()
    local file_size = handle:seek("end")
    handle:close()
    local final_state_offset_base = state_offset_bases and readLittleEndian24(
        state_offset_bases, (state_offset_base_count - 1) * 3 + 1)
    local final_state_offset_delta = state_offset_deltas and readLittleEndian16(
        state_offset_deltas, state_count * state_record_size + 1)
    if not state_offset_bases
            or #state_offset_bases ~= state_offset_base_count * 3
            or not state_offset_deltas
            or #state_offset_deltas ~= (state_count + 1) * state_record_size
            or not final_bitmap or #final_bitmap ~= final_bitmap_size
            or not final_ranks
            or #final_ranks ~= final_rank_count * G2P_RANK_RECORD_SIZE
            or not final_weights or #final_weights ~= final_count * 2
            or not arc_table_offset or not file_size
            or file_size ~= arc_table_offset + arc_count * arc_record_size
            or not final_state_offset_base or not final_state_offset_delta
            or final_state_offset_base + final_state_offset_delta ~= arc_count
            or readLittleEndian24(final_ranks,
                (final_rank_count - 1) * G2P_RANK_RECORD_SIZE + 1)
                ~= final_count then
        logger.warn("Pronunciation: bundled English G2P model is truncated")
        self.english_g2p_model = false
        return nil
    end

    self.english_g2p_model = {
        path = model_path,
        state_offset_bases = state_offset_bases,
        state_offset_deltas = state_offset_deltas,
        final_bitmap = final_bitmap,
        final_ranks = final_ranks,
        final_weights = final_weights,
        state_count = state_count,
        arc_count = arc_count,
        start_state = start_state,
        weight_scale = weight_scale,
        phone_table = phone_table,
        arc_table_offset = arc_table_offset,
    }
    return self.english_g2p_model
end

local LATIN_ASCII_FOLD = {
    ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ä"] = "a", ["ã"] = "a",
    ["å"] = "a", ["æ"] = "ae", ["ç"] = "c", ["é"] = "e", ["è"] = "e",
    ["ê"] = "e", ["ë"] = "e", ["í"] = "i", ["ì"] = "i", ["î"] = "i",
    ["ï"] = "i", ["ñ"] = "n", ["ó"] = "o", ["ò"] = "o", ["ô"] = "o",
    ["ö"] = "o", ["õ"] = "o", ["ø"] = "o", ["œ"] = "oe", ["ú"] = "u",
    ["ù"] = "u", ["û"] = "u", ["ü"] = "u", ["ý"] = "y", ["ÿ"] = "y",
}

local function foldEnglishSpelling(word)
    local lower = normalizeWord(word)
    local output = {}
    local position = 1
    while position <= #lower do
        local character = nextUtf8Character(lower, position)
        if not character then return nil end
        if character:match("^[a-z]$") then
            output[#output + 1] = character
        elseif LATIN_ASCII_FOLD[character] then
            output[#output + 1] = LATIN_ASCII_FOLD[character]
        elseif character == "'" then
            output[#output + 1] = character
        elseif character ~= "-" and character ~= " " then
            return nil
        end
        position = position + #character
    end
    local folded = table.concat(output)
    return folded ~= "" and folded or nil
end

function Pronunciation:_englishG2pPhones(word)
    local model = self:_loadEnglishG2pModel()
    local spelling = foldEnglishSpelling(word)
    if not model or not spelling or #spelling > G2P_MAX_WORD_BYTES then return nil end

    local handle = io.open(model.path, "rb")
    if not handle then return nil end
    local arc_cache = {}
    local decode_failed = false

    local function stateOffset(state)
        local block = math.floor(state / G2P_STATE_OFFSET_BLOCK)
        local base = readLittleEndian24(
            model.state_offset_bases, block * 3 + 1)
        local delta = readLittleEndian16(
            model.state_offset_deltas, state * G2P_STATE_RECORD_SIZE + 1)
        if not base or not delta then return nil end
        return base + delta
    end

    local function stateInfo(state, need_final_weight)
        if state < 0 or state >= model.state_count then
            decode_failed = true
            return
        end
        local first_arc = stateOffset(state)
        local next_arc = stateOffset(state + 1)
        if not first_arc or not next_arc or next_arc < first_arc then
            decode_failed = true
            return
        end

        local final_weight = G2P_INFINITE_FINAL
        if need_final_weight then
            local byte_position = math.floor(state / 8) + 1
            local bit_position = state % 8
            local byte = model.final_bitmap:byte(byte_position)
            local bit_value = 2 ^ bit_position
            if math.floor(byte / bit_value) % 2 == 1 then
                local block = math.floor(state / G2P_FINAL_RANK_BLOCK)
                local rank = readLittleEndian24(
                    model.final_ranks, block * G2P_RANK_RECORD_SIZE + 1)
                local first_byte = block * (G2P_FINAL_RANK_BLOCK / 8) + 1
                for index = first_byte, byte_position - 1 do
                    rank = rank + G2P_POPCOUNT[model.final_bitmap:byte(index)]
                end
                rank = rank + G2P_POPCOUNT[byte % bit_value]
                final_weight = readLittleEndian16(
                    model.final_weights, rank * 2 + 1)
                if not final_weight then
                    decode_failed = true
                    return
                end
            end
        end
        return first_arc, next_arc - first_arc, final_weight
    end

    local function stateArcs(state, first_arc, arc_count)
        local cached = arc_cache[state]
        if cached then return cached end
        if not first_arc or not arc_count
                or first_arc + arc_count > model.arc_count
                or not handle:seek("set", model.arc_table_offset
                    + first_arc * G2P_ARC_RECORD_SIZE) then
            decode_failed = true
            return
        end
        local data = handle:read(arc_count * G2P_ARC_RECORD_SIZE)
        if not data or #data ~= arc_count * G2P_ARC_RECORD_SIZE then
            decode_failed = true
            return
        end
        arc_cache[state] = data
        return data
    end

    local start_key = model.start_state
    local distances = { [start_key] = 0 }
    local predecessors = {}
    local queue = { [1] = start_key }
    local queued = { [start_key] = true }
    local head, tail = 1, 1
    local relaxations = 0
    local best_cost
    local best_key

    while head <= tail and not decode_failed do
        local key = queue[head]
        queue[head] = nil
        head = head + 1
        queued[key] = nil

        local state = key % model.state_count
        local input_position = (key - state) / model.state_count
        local cost = distances[key]
        local at_end = input_position == #spelling
        local first_arc, arc_count, final_weight = stateInfo(state, at_end)
        if decode_failed then break end

        if at_end and final_weight ~= G2P_INFINITE_FINAL then
            local total_cost = cost + final_weight
            if not best_cost or total_cost < best_cost then
                best_cost = total_cost
                best_key = key
            end
        end

        local arcs = stateArcs(state, first_arc, arc_count)
        if decode_failed then break end
        local wanted = spelling:byte(input_position + 1)
        for position = 1, #arcs, G2P_ARC_RECORD_SIZE do
            local packed_input = arcs:byte(position)
            local input_code = packed_input % 32
            local input_label = input_code == 0 and 0
                or (input_code == 1 and 39 or input_code + 95)
            if input_label == 0 or input_label == wanted then
                local packed_output = arcs:byte(position + 1)
                local output_label = packed_output % 128
                local weight = readSignedLittleEndian16(arcs, position + 2)
                local next_state_low = readLittleEndian16(arcs, position + 4)
                local next_state = next_state_low and next_state_low
                    + (math.floor(packed_input / 32)
                        + math.floor(packed_output / 128) * 8) * 65536
                if not weight or not next_state
                        or next_state >= model.state_count
                        or output_label > #model.phone_table then
                    decode_failed = true
                    break
                end
                local next_input_position = input_position
                    + (input_label == 0 and 0 or 1)
                local next_key = next_input_position * model.state_count
                    + next_state
                local next_cost = cost + weight
                local old_cost = distances[next_key]
                if not old_cost or next_cost < old_cost then
                    distances[next_key] = next_cost
                    predecessors[next_key] = key * 128 + output_label
                    relaxations = relaxations + 1
                    if relaxations > G2P_MAX_RELAXATIONS then
                        logger.warn("Pronunciation: English G2P decode limit exceeded")
                        decode_failed = true
                        break
                    end
                    if not queued[next_key] then
                        tail = tail + 1
                        queue[tail] = next_key
                        queued[next_key] = true
                    end
                end
            end
        end
    end
    handle:close()
    if decode_failed or not best_key then return nil end

    local output = {}
    local key = best_key
    local path_steps = 0
    while key ~= start_key do
        local packed = predecessors[key]
        if not packed then return nil end
        local output_label = packed % 128
        if output_label ~= 0 then
            output[#output + 1] = model.phone_table[output_label]
        end
        key = math.floor(packed / 128)
        path_steps = path_steps + 1
        if path_steps > G2P_MAX_RELAXATIONS then return nil end
    end
    if #output == 0 then return nil end
    for left = 1, math.floor(#output / 2) do
        local right = #output - left + 1
        output[left], output[right] = output[right], output[left]
    end
    return output
end

local PORTABLE_GENERATORS = {
    en = function(plugin, word)
        local phones = plugin:_englishG2pPhones(word)
        if not phones then return nil end
        return {
            ipa = arpabetPhonesToIpa(phones),
            arpabet = table.concat(phones, " "),
            source = "MFA/Pynini English G2P",
            confidence = 45,
        }
    end,
}

function Pronunciation:generatePronunciations(word, hints)
    if not self.generated_fallback then return nil end
    local results = {}
    local seen = {}

    local function add(generated, definition)
        if not generated then return end
        local ipa = normalizeOnlineIpa(generated.ipa)
        if not ipa then return end
        local key = stripIpaWrappers(ipa) .. "\0" .. definition.code
        if seen[key] then return end
        seen[key] = true
        results[#results + 1] = {
            ipa = ipa,
            arpabet = generated.arpabet,
            simple = readableFromIpa(ipa),
            simple_approx = true,
            language = definition.name,
            region = definition.region,
            source = generated.source,
            confidence = generated.confidence,
            generated = true,
        }
    end

    for _, hint in ipairs(mergeLanguageHints(hints)) do
        local generator = PORTABLE_GENERATORS[hint.code]
        if generator then add(generator(self, word), hint) end
    end

    -- An unknown or unsupported book language still gets the portable US
    -- English reading as an explicitly labeled adaptation.
    if #results == 0 then
        local english = LANGUAGE_DEFINITIONS.english
        add(PORTABLE_GENERATORS.en(self, word), english)
    end
    if #results > 0 then return results end
end

function Pronunciation:documentLanguageHints()
    local document = self.ui and self.ui.document
    if not document or type(document.getProps) ~= "function" then return {} end
    local ok, properties = pcall(document.getProps, document)
    if not ok or type(properties) ~= "table"
            or type(properties.language) ~= "string" then return {} end

    local hints = {}
    for value in properties.language:gmatch("[^,;]+") do
        local definition = languageDefinition(nil, value)
        if definition then
            hints[#hints + 1] = {
                code = definition.code,
                name = definition.name,
                source = "Book metadata",
            }
        end
    end
    return mergeLanguageHints(hints)
end

function Pronunciation:generationHints(word, online_hints)
    if self.generated_language and self.generated_language ~= "auto" then
        local selected = languageDefinition(nil, self.generated_language)
        if selected then
            return mergeLanguageHints({{
                code = selected.code,
                name = selected.name,
                source = "User-selected generated language",
            }})
        end
    end
    return mergeLanguageHints(
        self:queryLanguageHints(word),
        online_hints,
        self:documentLanguageHints()
    )
end

function Pronunciation:generationCacheKey(word, hints)
    local languages = {}
    for _, hint in ipairs(hints or {}) do
        languages[#languages + 1] = hint.code
    end
    return "generator:" .. GENERATOR_VERSION
        .. "|preference:" .. (self.generated_language or "auto")
        .. "|languages:" .. table.concat(languages, ",")
        .. "|word:" .. normalizeWord(word)
end

local function pruneResultCache(cache, limit, protected_key, required_prefix)
    if type(cache) ~= "table" then return false end
    local count = 0
    local changed = false
    for key, results in pairs(cache) do
        local valid = type(key) == "string"
            and type(results) == "table" and #results > 0
            and (not required_prefix
                or key:sub(1, #required_prefix) == required_prefix)
        if valid then
            for _, result in ipairs(results) do
                if type(result) ~= "table" then
                    valid = false
                    break
                end
                -- Descriptive notes are retained in the bundled database for
                -- provenance, but are not displayed and should not bloat the
                -- settings file or resident cache.
                if result.note ~= nil then
                    result.note = nil
                    changed = true
                end
            end
        end
        if not valid then
            cache[key] = nil
            changed = true
        else
            count = count + 1
        end
    end
    if count <= limit then return changed end
    for key in pairs(cache) do
        if count <= limit then break end
        if key ~= protected_key then
            cache[key] = nil
            count = count - 1
            changed = true
        end
    end
    return changed
end

local function pruneSourcedCache(cache, protected_key)
    return pruneResultCache(cache, SOURCED_CACHE_LIMIT, protected_key)
end

local function pruneGeneratedCache(cache, protected_key)
    return pruneResultCache(cache, GENERATED_CACHE_LIMIT, protected_key,
        GENERATED_CACHE_PREFIX)
end

function Pronunciation:init()
    self.db_path = self.path .. "/data/pronunciations.sqlite3"
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/pronunciation.lua")
    self.overrides = self.settings:readSetting("overrides", {})
    self.cache = self.settings:readSetting("cache", {})
    self.generated_cache = self.settings:readSetting("generated_cache", {})
    if type(self.overrides) ~= "table" then self.overrides = {} end
    if type(self.cache) ~= "table" then self.cache = {} end
    if type(self.generated_cache) ~= "table" then self.generated_cache = {} end
    self.online_fallback = self.settings:readSetting("online_fallback", true)
    self.generated_fallback = self.settings:readSetting("generated_fallback", true)
    self.generated_language = self.settings:readSetting("generated_language", "auto")
    if self.generated_language ~= "auto" then
        local selected = languageDefinition(nil, self.generated_language)
        self.generated_language = selected
            and SELECTABLE_GENERATION_LANGUAGES[selected.code]
            and selected.code or "auto"
    end

    -- v0.5 separates sourced and generated caches and keys generated entries
    -- by language choice so results cannot leak between books.
    if self.settings:readSetting("cache_version") ~= CACHE_VERSION then
        self.cache = {}
        self.generated_cache = {}
        self.settings:saveSetting("cache", self.cache)
        self.settings:saveSetting("generated_cache", self.generated_cache)
        self.settings:saveSetting("cache_version", CACHE_VERSION)
        self.settings:flush()
    else
        -- Old generator formats are never reused, and generated entries can
        -- always be recreated offline. Both recoverable caches remain bounded
        -- so pronunciation.lua cannot grow indefinitely on long-lived devices.
        local cache_changed = pruneSourcedCache(self.cache)
        local generated_changed = pruneGeneratedCache(self.generated_cache)
        if cache_changed then
            self.settings:saveSetting("cache", self.cache)
        end
        if generated_changed then
            self.settings:saveSetting("generated_cache", self.generated_cache)
        end
        if cache_changed or generated_changed then self.settings:flush() end
    end

    self.ui.menu:registerToMainMenu(self)
    self:registerDictionaryButton()
end

function Pronunciation:_dictionaryButtonSpec()
    return {
        id = "pronunciation_lookup",
        text = _("Pronunciation"),
        -- Conditional buttons are appended even when a user has an older saved layout.
        conditional = true,
        row_group = "pronunciation",
        show_func = function(dict_popup)
            return not dict_popup.is_wiki_fullpage
        end,
        callback = function(dict_popup)
            self:lookupAndShow(popupQueryWord(dict_popup))
        end,
        hold_callback = function(dict_popup)
            self:editOverride(popupQueryWord(dict_popup))
        end,
    }
end

function Pronunciation:registerDictionaryButton()
    local dictionary = self.ui and self.ui.dictionary
    if dictionary and type(dictionary.addToDictButtons) == "function" then
        self.uses_modern_dictionary_buttons = true
        dictionary:addToDictButtons(self:_dictionaryButtonSpec())
    else
        -- KOReader v2022.06-v2024.02 called a tweak_buttons_func method on
        -- each popup. Patch init once so we can chain whichever plugin owns
        -- that old single-callback slot when a popup is actually created.
        if not DictQuickLookup then
            DictQuickLookup = require("ui/widget/dictquicklookup")
        end
        DictQuickLookup._pronunciation_plugin_instance = self
        if not DictQuickLookup._pronunciation_original_init then
            DictQuickLookup._pronunciation_original_init = DictQuickLookup.init
            DictQuickLookup.init = function(dict_popup, ...)
                local previous_tweak = dict_popup.tweak_buttons_func
                dict_popup.tweak_buttons_func = function(popup, buttons)
                    if previous_tweak then previous_tweak(popup, buttons) end
                    local plugin = DictQuickLookup._pronunciation_plugin_instance
                    if plugin then plugin:_insertLegacyButton(popup, buttons) end
                end
                return DictQuickLookup._pronunciation_original_init(dict_popup, ...)
            end
        end
    end
end

local function containsButton(buttons, id)
    for _, row in ipairs(buttons or {}) do
        for _, button in ipairs(row) do
            if button.id == id then return true end
        end
    end
    return false
end

function Pronunciation:_insertLegacyButton(dict_popup, buttons)
    if not dict_popup or dict_popup.is_wiki_fullpage
            or containsButton(buttons, "pronunciation_lookup") then return end
    table.insert(buttons, 1, {{
        id = "pronunciation_lookup",
        text = _("Pronunciation"),
        callback = function()
            self:lookupAndShow(popupQueryWord(dict_popup))
        end,
        hold_callback = function()
            self:editOverride(popupQueryWord(dict_popup))
        end,
    }})
end

-- KOReader v2024.03-v2026.03 use this event instead of addToDictButtons().
function Pronunciation:onDictButtonsReady(dict_popup, buttons)
    if self.uses_modern_dictionary_buttons
            or (self.ui and self.ui.dictionary
                and type(self.ui.dictionary.addToDictButtons) == "function") then
        return
    end
    self:_insertLegacyButton(dict_popup, buttons)
end

function Pronunciation:addToMainMenu(menu_items)
    local generated_language_items = {
        {
            text = _("Auto (word or book language)"),
            checked_func = function() return self.generated_language == "auto" end,
            callback = function() self:setGeneratedLanguage("auto") end,
        },
    }
    for _, key in ipairs(GENERATION_LANGUAGE_ORDER) do
        local definition = LANGUAGE_DEFINITIONS[key]
        generated_language_items[#generated_language_items + 1] = {
            text = definition.region
                and definition.region .. " " .. definition.name
                or definition.name,
            checked_func = function()
                return self.generated_language == definition.code
            end,
            callback = function()
                self:setGeneratedLanguage(definition.code)
            end,
        }
    end

    menu_items.pronunciation = {
        sorting_hint = "tools",
        text = _("Pronunciation dictionary"),
        sub_item_table = {
            {
                text_func = function()
                    return self.online_fallback
                        and _("Online fallback: on") or _("Online fallback: off")
                end,
                keep_menu_open = true,
                callback = function()
                    self.online_fallback = not self.online_fallback
                    self.settings:saveSetting("online_fallback", self.online_fallback)
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    return self.generated_fallback
                        and _("Generated fallback: on") or _("Generated fallback: off")
                end,
                keep_menu_open = true,
                callback = function()
                    self.generated_fallback = not self.generated_fallback
                    self.settings:saveSetting("generated_fallback",
                        self.generated_fallback)
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    if self.generated_language == "auto" then
                        return _("Generated language") .. ": " .. _("Auto")
                    end
                    local definition = languageDefinition(nil,
                        self.generated_language)
                    local label = definition and definition.name
                        or self.generated_language
                    if definition and definition.region then
                        label = definition.region .. " " .. label
                    end
                    return _("Generated language") .. ": " .. label
                end,
                sub_item_table = generated_language_items,
            },
            {
                text = _("Clear cached pronunciations"),
                callback = function()
                    self.cache = {}
                    self.generated_cache = {}
                    self.settings:saveSetting("cache", self.cache)
                    self.settings:saveSetting("generated_cache",
                        self.generated_cache)
                    self.settings:flush()
                end,
            },
            {
                text = _("About pronunciation dictionary"),
                callback = function()
                    UIManager:show(newInfoMessage{
                        text = _("Offline US/UK IPA, sourced online lookup, and a bundled US English fallback for unfamiliar words. Long-press Pronunciation to save an override.")
                            .. "\n\n" .. _("Version") .. ": " .. PLUGIN_VERSION,
                    })
                end,
            },
        },
    }
end

function Pronunciation:setGeneratedLanguage(code)
    if code ~= "auto" and not SELECTABLE_GENERATION_LANGUAGES[code] then return end
    self.generated_language = code
    self.generated_cache = {}
    self.settings:saveSetting("generated_language", code)
    self.settings:saveSetting("generated_cache", self.generated_cache)
    self.settings:flush()
end

function Pronunciation:getOverride(word)
    local override = self.overrides[normalizeWord(word)]
    if type(override) == "table" then
        return {{
            ipa = wrapIpa(override.ipa),
            simple = override.simple,
            source = "Personal override",
            confidence = 100,
            simple_approx = false,
        }}
    end
end

function Pronunciation:getCache(word)
    local cached = self.cache[normalizeWord(word)]
    if type(cached) == "table" and #cached > 0 then
        return ensureReadables(cached)
    end
end

local function closeSqlResource(resource)
    if resource then pcall(function() resource:close() end) end
end

local function boldHeading(text)
    -- TextBoxWidget's inline-bold markers were added after the oldest KOReader
    -- versions supported by this plugin. Use them when available and degrade
    -- to an unchanged plain heading on older builds.
    if TextBoxWidget == nil then
        local ok, module = pcall(require, "ui/widget/textboxwidget")
        TextBoxWidget = ok and module or false
    end
    if not TextBoxWidget or not TextBoxWidget.PTF_HEADER
            or not TextBoxWidget.PTF_BOLD_START
            or not TextBoxWidget.PTF_BOLD_END then
        return text
    end
    return TextBoxWidget.PTF_HEADER .. TextBoxWidget.PTF_BOLD_START
        .. text .. TextBoxWidget.PTF_BOLD_END
end

local PRONUNCIATION_QUERY = [[
    SELECT ipa, arpabet, simple, source, confidence, region, simple_approx
      FROM pronunciations
     WHERE word = ?
  ORDER BY confidence DESC, source, region, ipa
]]

function Pronunciation:_queryConnection(connection, word, statement)
    local ok, results = pcall(function()
        if statement then
            statement:reset()
        else
            statement = connection:prepare(PRONUNCIATION_QUERY)
        end
        statement:bind(word)
        local rows = {}
        while true do
            local row = statement:step()
            if not row then break end
            local language = languageDefinition(row[6], nil)
            rows[#rows + 1] = {
                ipa = row[1],
                arpabet = row[2],
                simple = row[3],
                source = row[4],
                confidence = tonumber(row[5]) or 0,
                region = language and nil or row[6],
                language = language and language.name or nil,
                simple_approx = tonumber(row[7]) == 1,
            }
        end
        return rows
    end)
    if not ok then
        closeSqlResource(statement)
        return nil, results, nil
    end
    if #results > 0 then
        ensureReadables(results)
        -- Prefer an English/curated exact entry over a foreign homograph.
        -- Foreign-only matches remain available for rare borrowed words.
        local english = {}
        for _, result in ipairs(results) do
            if not result.language or result.language == "English" then
                english[#english + 1] = result
            end
        end
        return #english > 0 and english or results, nil, statement
    end
    return nil, nil, statement
end

function Pronunciation:query(word)
    local opened, connection = pcall(openDatabase, self.db_path)
    if not opened or not connection then
        logger.err("Pronunciation: database open failed:", connection)
        return nil
    end
    local results, query_error, statement = self:_queryConnection(connection,
        normalizeWord(word))
    closeSqlResource(statement)
    closeSqlResource(connection)
    if query_error then
        logger.err("Pronunciation: database lookup failed:", query_error)
    end
    return results
end

function Pronunciation:queryLanguageHints(word)
    local connection
    local statement
    local ok, results = pcall(function()
        connection = openDatabase(self.db_path)
        statement = connection:prepare([[
            SELECT language_code, language_name, source
              FROM language_hints
             WHERE word = ?
          ORDER BY language_name
        ]])
        statement:bind(normalizeWord(word))
        local rows = {}
        while true do
            local row = statement:step()
            if not row then break end
            rows[#rows + 1] = {
                code = row[1],
                name = row[2],
                source = row[3],
            }
        end
        return rows
    end)
    closeSqlResource(statement)
    closeSqlResource(connection)
    -- Older v0.3 databases do not have language_hints; treat that as no hint.
    if not ok then return {} end
    return mergeLanguageHints(results)
end

local function lastArpabetPhone(arpabet)
    if not arpabet then return nil end
    local last
    for phone in arpabet:gmatch("%S+") do
        last = phone:gsub("[012]$", "")
    end
    return last
end

local function lastIpaPhone(ipa)
    local phones = tokenizeIpa(ipa)
    return phones[#phones] and phones[#phones].symbol or nil
end

local SIBILANTS = {
    S = true, Z = true, SH = true, ZH = true, CH = true, JH = true,
    ["s"] = true, ["z"] = true, ["ʃ"] = true, ["ʒ"] = true,
    ["tʃ"] = true, ["dʒ"] = true,
}
local VOICELESS = {
    P = true, T = true, K = true, F = true, TH = true,
    ["p"] = true, ["t"] = true, ["k"] = true,
    ["f"] = true, ["θ"] = true, ["x"] = true,
}
local PAST_VOICELESS = {
    P = true, K = true, F = true, S = true, SH = true, CH = true, TH = true,
    ["p"] = true, ["k"] = true, ["f"] = true, ["s"] = true,
    ["ʃ"] = true, ["tʃ"] = true, ["θ"] = true, ["x"] = true,
}

local function finalPhone(result)
    return lastArpabetPhone(result.arpabet) or lastIpaPhone(result.ipa)
end

local function pluralSuffix(phone)
    if SIBILANTS[phone] then return "ɪz" end
    if VOICELESS[phone] then return "s" end
    return "z"
end

local function pastSuffix(phone)
    if phone == "T" or phone == "D" or phone == "t" or phone == "d" then
        return "ɪd"
    end
    if PAST_VOICELESS[phone] then return "t" end
    return "d"
end

local function appendIpa(ipa, suffix)
    local core = stripIpaWrappers(ipa)
    if core == "" then return nil end
    return "/" .. core .. suffix .. "/"
end

function Pronunciation:derive(base_results, kind, shown_base)
    local results = {}
    for _, base in ipairs(base_results) do
        if not base.language or base.language == "English" then
            local suffix
            if kind == "plural" or kind == "possessive" then
                suffix = pluralSuffix(finalPhone(base))
            elseif kind == "past" then
                suffix = pastSuffix(finalPhone(base))
            elseif kind == "ing" then
                suffix = "ɪŋ"
            end
            local ipa = suffix and appendIpa(base.ipa, suffix)
            if ipa then
                results[#results + 1] = {
                    ipa = ipa,
                    simple = readableFromIpa(ipa),
                    simple_approx = true,
                    region = base.region,
                    language = base.language,
                    source = (base.source or "Offline") .. " + derived inflection",
                    confidence = math.max(50, (base.confidence or 70) - 10),
                }
            end
        end
    end
    if #results > 0 then return results end
end

local function addCandidate(candidates, seen, word, kind)
    if word and word ~= "" then
        local key = word .. "\0" .. kind
        if not seen[key] then
            seen[key] = true
            candidates[#candidates + 1] = { word = word, kind = kind }
        end
    end
end

function Pronunciation:candidates(word)
    local candidates = {}
    local seen = {}

    if word:match("'s$") then
        addCandidate(candidates, seen, word:sub(1, -3), "possessive")
    end
    if word:match("ies$") and #word > 4 then
        addCandidate(candidates, seen, word:sub(1, -4) .. "y", "plural")
    end
    if word:match("ves$") and #word > 4 then
        addCandidate(candidates, seen, word:sub(1, -4) .. "f", "plural")
        addCandidate(candidates, seen, word:sub(1, -4) .. "fe", "plural")
    end
    if word:match("oes$") and #word > 4 then
        addCandidate(candidates, seen, word:sub(1, -3), "plural")
    end
    if word:match("sses$") or word:match("shes$") or word:match("ches$")
            or word:match("xes$") or word:match("zes$") then
        addCandidate(candidates, seen, word:sub(1, -3), "plural")
    end
    if word:match("es$") and #word > 3 then
        addCandidate(candidates, seen, word:sub(1, -3), "plural")
    end
    if word:match("s$") and not word:match("ss$") and #word > 2 then
        addCandidate(candidates, seen, word:sub(1, -2), "plural")
    end

    if word:match("ied$") and #word > 4 then
        addCandidate(candidates, seen, word:sub(1, -4) .. "y", "past")
    end
    if word:match("ed$") and #word > 3 then
        local without_ed = word:sub(1, -3)
        addCandidate(candidates, seen, without_ed, "past")
        if without_ed:sub(-1) == without_ed:sub(-2, -2) then
            addCandidate(candidates, seen, without_ed:sub(1, -2), "past")
        end
        addCandidate(candidates, seen, word:sub(1, -2), "past")
    end

    if word:match("ying$") and #word > 4 then
        addCandidate(candidates, seen, word:sub(1, -5) .. "ie", "ing")
    end
    if word:match("ing$") and #word > 4 then
        local without_ing = word:sub(1, -4)
        addCandidate(candidates, seen, without_ing, "ing")
        if without_ing:sub(-1) == without_ing:sub(-2, -2) then
            addCandidate(candidates, seen, without_ing:sub(1, -2), "ing")
        end
        addCandidate(candidates, seen, without_ing .. "e", "ing")
    end
    return candidates
end

function Pronunciation:lookupOffline(word)
    word = normalizeWord(word)
    local results = self:getOverride(word)
    if results then return results, word end

    -- Reuse one SQLite connection while checking the exact word and all
    -- possible inflection bases. Opening the bundled database repeatedly is
    -- noticeably expensive on low-memory e-ink devices.
    local opened, connection = pcall(openDatabase, self.db_path)
    if not opened or not connection then
        logger.err("Pronunciation: database open failed:", connection)
        connection = nil
    end
    local statement
    local function queryDatabase(candidate_word)
        if not connection then return nil end
        local rows, query_error, reusable_statement = self:_queryConnection(
            connection, candidate_word, statement)
        if reusable_statement then
            statement = reusable_statement
        elseif query_error then
            statement = nil
        end
        if query_error then
            logger.err("Pronunciation: database lookup failed:", query_error)
            closeSqlResource(statement)
            statement = nil
            closeSqlResource(connection)
            connection = nil
        end
        return rows
    end
    local function finish(found, matched)
        closeSqlResource(statement)
        statement = nil
        closeSqlResource(connection)
        connection = nil
        return found, matched
    end

    results = queryDatabase(word)
    if results then return finish(results, word) end
    results = self:getCache(word)
    if results then return finish(results, word) end

    for _, candidate in ipairs(self:candidates(word)) do
        local base = self:getOverride(candidate.word)
            or queryDatabase(candidate.word)
            or self:getCache(candidate.word)
        if base then
            local derived = self:derive(base, candidate.kind, candidate.word)
            if derived then return finish(derived, candidate.word) end
        end
    end
    return finish()
end

local function httpGet(request_url)
    loadOnlineModules()
    local sink = {}
    socketutil:set_timeout()
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request{
            url = request_url,
            method = "GET",
            sink = socketutil.table_sink and socketutil.table_sink(sink)
                or ltn12.sink.table(sink),
            headers = {
                ["Accept"] = "application/json",
                ["Accept-Encoding"] = "identity",
                ["User-Agent"] = socketutil.USER_AGENT
                    or "KOReader-Pronunciation/" .. PLUGIN_VERSION,
            },
        })
    end)
    socketutil:reset_timeout()
    if not ok or code ~= 200 then
        logger.warn("Pronunciation: HTTP request failed:", request_url, status or code)
        return nil
    end
    return table.concat(sink), headers
end

local function decodeEntities(text)
    return (text or "")
        :gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&#39;", "'")
        :gsub("&quot;", '"')
end

local function stripHtml(text)
    return trim(decodeEntities((text or ""):gsub("<.->", " "))
        :gsub("%s+", " "))
end

local function inferRegion(label)
    local lower = stripHtml(label):lower()
    if lower:find("general american", 1, true)
            or lower:find("united states", 1, true)
            or lower:find("(us)", 1, true)
            or lower:find("california", 1, true) then
        return "US"
    elseif lower:find("received pronunciation", 1, true)
            or lower:find("united kingdom", 1, true)
            or lower:find("(uk)", 1, true)
            or lower:find("british", 1, true) then
        return "UK"
    elseif lower:find("canada", 1, true) then
        return "Canada"
    elseif lower:find("australia", 1, true) then
        return "Australia"
    elseif lower:find("new zealand", 1, true) then
        return "New Zealand"
    elseif lower:find("ireland", 1, true) or lower:find("irish", 1, true) then
        return "Ireland"
    end
end

local function inferRegionFromAudio(audio)
    local lower = (audio or ""):lower()
    if lower:find("_us_", 1, true) or lower:find("-us-", 1, true)
            or lower:find("american", 1, true) then
        return "US"
    elseif lower:find("_gb_", 1, true) or lower:find("_uk_", 1, true)
            or lower:find("-uk-", 1, true) or lower:find("british", 1, true) then
        return "UK"
    end
end

normalizeOnlineIpa = function(ipa)
    return wrapIpa(ipa)
end

local function resultKey(result)
    return stripIpaWrappers(result.ipa) .. "\0"
        .. (result.language or "") .. "\0" .. (result.region or "")
end

local function mergeResults(...)
    local merged = {}
    local by_key = {}
    for i = 1, select("#", ...) do
        for _, result in ipairs(select(i, ...) or {}) do
            if result.ipa then
                ensureReadable(result)
                local key = resultKey(result)
                local existing = by_key[key]
                if not existing then
                    by_key[key] = result
                    merged[#merged + 1] = result
                elseif result.source and existing.source
                        and not existing.source:find(result.source, 1, true) then
                    existing.source = existing.source .. " + " .. result.source
                    existing.confidence = math.max(existing.confidence or 0,
                        result.confidence or 0)
                end
            end
        end
    end
    if #merged > 0 then
        table.sort(merged, function(left, right)
            local left_confidence = left.confidence or 0
            local right_confidence = right.confidence or 0
            if left_confidence ~= right_confidence then
                return left_confidence > right_confidence
            end
            local left_key = (left.source or "") .. "\0"
                .. (left.region or "") .. "\0" .. (left.ipa or "")
            local right_key = (right.source or "") .. "\0"
                .. (right.region or "") .. "\0" .. (right.ipa or "")
            return left_key < right_key
        end)
        return merged
    end
end

function Pronunciation:parseDictionaryApi(decoded)
    if type(decoded) ~= "table" then return nil end
    local results = {}
    local seen = {}
    local seen_ipa = {}
    local function add(ipa, region)
        ipa = normalizeOnlineIpa(ipa)
        if not ipa then return end
        local bare_ipa = stripIpaWrappers(ipa)
        local key = bare_ipa .. "\0" .. (region or "")
        if seen[key] then return end
        seen[key] = true
        seen_ipa[bare_ipa] = true
        results[#results + 1] = {
            ipa = ipa,
            simple = readableFromIpa(ipa),
            simple_approx = true,
            region = region,
            source = "Free Dictionary API",
            confidence = 75,
        }
    end

    for _, entry in ipairs(decoded) do
        for _, phonetic in ipairs(entry.phonetics or {}) do
            add(phonetic.text, inferRegionFromAudio(phonetic.audio))
        end
        local bare_entry_ipa = entry.phonetic
            and stripIpaWrappers(entry.phonetic) or nil
        if not bare_entry_ipa or not seen_ipa[bare_entry_ipa] then
            add(entry.phonetic)
        end
    end
    if #results > 0 then return results end
end

function Pronunciation:dictApi(word)
    loadOnlineModules()
    local body = httpGet("https://api.dictionaryapi.dev/api/v2/entries/en/"
        .. url.escape(word))
    if not body then return nil end
    local ok, decoded = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok then return nil end
    return self:parseDictionaryApi(decoded)
end

local function englishWiktionarySection(html)
    local english_id = html:find('id="English"', 1, true)
    if not english_id then return nil end
    local next_h2 = html:find('<h2[^>]-id="', english_id + #('id="English"'))
    local next_heading = html:find(
        '<div[^>]-class="[^"]-mw%-heading2[^"]-"',
        english_id + #('id="English"'))
    local finish
    if next_h2 and next_heading then finish = math.min(next_h2, next_heading) - 1
    elseif next_h2 then finish = next_h2 - 1
    elseif next_heading then finish = next_heading - 1
    else finish = #html end
    return html:sub(english_id, finish)
end

local function extractIpaSpans(fragment, callback)
    local found = false
    for raw_ipa in fragment:gmatch(
            '<span[^>]-class="[^"]*IPA[^"]*"[^>]*>(.-)</span>') do
        local text = stripHtml(raw_ipa)
        local first = text:sub(1, 1)
        local last = text:sub(-1)
        local paired = (first == "/" and last == "/")
            or (first == "[" and last == "]")
        local core = paired and stripIpaWrappers(text) or ""
        -- Wiktionary also marks rhyme endings and hyphenation fragments with
        -- class=IPA. They are not complete word pronunciations.
        local ipa
        if core ~= "" and core:sub(1, 1) ~= "-"
                and core:sub(-1) ~= "-" then
            ipa = wrapIpa(core)
        end
        if ipa then
            found = true
            callback(ipa)
        end
    end
    return found
end

local function extractEtymologyLanguageHints(english)
    local hints = {}
    for fragment in (english or ""):gmatch(
            '<span[^>]-class="[^"]*etyl[^"]*"[^>]*>(.-)</span>') do
        local name = stripHtml(fragment)
        local definition = languageDefinition(name, nil)
        if definition then
            hints[#hints + 1] = {
                code = definition.code,
                name = definition.name,
                source = "Wiktionary etymology",
            }
        end
    end
    return mergeLanguageHints(hints)
end

function Pronunciation:parseWiktionaryHtml(html)
    local english = englishWiktionarySection(html or "")
    if not english then return nil end
    local language_hints = extractEtymologyLanguageHints(english)

    local results = {}
    local seen = {}
    local function add(ipa, region)
        local key = stripIpaWrappers(ipa) .. "\0" .. (region or "")
        if seen[key] then return end
        seen[key] = true
        results[#results + 1] = {
            ipa = ipa,
            simple = readableFromIpa(ipa),
            simple_approx = true,
            region = region,
            source = "Wiktionary",
            confidence = 85,
        }
    end

    local found_in_items = false
    for item in english:gmatch("<li[^>]*>(.-)</li>") do
        local region = inferRegion(item)
        if extractIpaSpans(item, function(ipa) add(ipa, region) end) then
            found_in_items = true
        end
    end
    if not found_in_items then
        extractIpaSpans(english, function(ipa) add(ipa, nil) end)
    end
    if #results > 0 then return results, language_hints end
    return nil, language_hints
end

function Pronunciation:wiktionary(word)
    loadOnlineModules()
    local body = httpGet("https://en.wiktionary.org/w/api.php"
        .. "?action=parse&format=json&formatversion=2&redirects=1&prop=text&page="
        .. url.escape(word))
    if not body then return nil end
    local ok, decoded = pcall(JSON.decode, body, JSON.decode.simple)
    if not ok or not decoded or not decoded.parse or not decoded.parse.text then
        return nil
    end
    local html = decoded.parse.text
    if type(html) == "table" then html = html["*"] end
    if type(html) ~= "string" then return nil end
    return self:parseWiktionaryHtml(html)
end

function Pronunciation:lookupOnline(word)
    local dictionary = self:dictApi(word)
    local wiktionary, language_hints = self:wiktionary(word)
    return mergeResults(dictionary, wiktionary), language_hints
end

function Pronunciation:saveCache(word, results)
    local key = normalizeWord(word)
    self.cache[key] = results
    pruneSourcedCache(self.cache, key)
    self.settings:saveSetting("cache", self.cache)
    self.settings:saveSetting("cache_version", CACHE_VERSION)
    self.settings:flush()
end

function Pronunciation:getGeneratedCache(key)
    local cached = (self.generated_cache or {})[key]
    if type(cached) == "table" and #cached > 0 then
        return ensureReadables(cached)
    end
end

function Pronunciation:saveGeneratedCache(key, results)
    self.generated_cache = self.generated_cache or {}
    self.generated_cache[key] = results
    pruneGeneratedCache(self.generated_cache, key)
    self.settings:saveSetting("generated_cache", self.generated_cache)
    self.settings:saveSetting("cache_version", CACHE_VERSION)
    self.settings:flush()
end

function Pronunciation:format(original, results, matched)
    local lines = { boldHeading(original) }
    if matched and normalizeWord(original) ~= matched then
        lines[#lines + 1] = _("Matched/derived from") .. ": " .. matched
    end
    lines[#lines + 1] = ""
    for index, result in ipairs(results) do
        local location
        if result.language == "English" and result.region then
            location = result.region .. " English"
        else
            location = result.language or result.region
        end
        local qualifiers = {}
        if result.generated then qualifiers[#qualifiers + 1] = _("generated") end
        if location then qualifiers[#qualifiers + 1] = location end
        local qualifier = #qualifiers > 0
            and " (" .. table.concat(qualifiers, "; ") .. ")" or ""
        lines[#lines + 1] = _("IPA") .. qualifier .. ": " .. (result.ipa or "—")
        if result.simple and result.simple ~= "" then
            local qualifier = result.simple_approx
                and " (" .. _("approx.") .. ")" or ""
            lines[#lines + 1] = _("Readable") .. qualifier .. ": " .. result.simple
        end
        if result.source then
            lines[#lines + 1] = _("Source") .. ": " .. result.source
        end
        if index < #results then lines[#lines + 1] = "" end
    end
    return table.concat(lines, "\n")
end

function Pronunciation:generatedForWord(word, online_hints)
    if not self.generated_fallback then return nil end
    local hints = self:generationHints(word, online_hints)
    local cache_key = self:generationCacheKey(word, hints)
    local cached = self:getGeneratedCache(cache_key)
    if cached then return cached end
    local generated = self:generatePronunciations(word, hints)
    if generated then self:saveGeneratedCache(cache_key, generated) end
    return generated
end

function Pronunciation:_lookupOnlineAndShow(word, progress)
    local normalized = normalizeWord(word)
    local online, language_hints = self:lookupOnline(normalized)
    local online_match = normalized
    if not online then
        for _, candidate in ipairs(self:candidates(normalized)) do
            local base = self:lookupOnline(candidate.word)
            if base then
                online = self:derive(base, candidate.kind, candidate.word)
                online_match = candidate.word
                if online then break end
            end
        end
    end
    if online then
        self:saveCache(normalized, online)
        showLookupMessage(progress, self:format(word, online, online_match))
    else
        local generated = self:generatedForWord(normalized, language_hints)
        if generated then
            showLookupMessage(progress, self:format(word, generated, normalized))
        else
            showLookupMessage(progress,
                word .. "\n\n"
                    .. _("No pronunciation found offline or online. Long-press Pronunciation to save your own IPA/readable pronunciation."))
        end
    end
end

function Pronunciation:_lookupAndShow(word, progress)
    local results, matched = self:lookupOffline(word)
    if results then
        showLookupMessage(progress, self:format(word, results, matched))
        return
    end
    if not self.online_fallback then
        local generated = self:generatedForWord(normalizeWord(word))
        if generated then
            showLookupMessage(progress,
                self:format(word, generated, normalizeWord(word)))
            return
        end
        showLookupMessage(progress,
            word .. "\n\n"
                .. _("No offline pronunciation found. Long-press Pronunciation to add a personal override."))
        return
    end

    if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
    local callback_ran = false
    local progress_closed = false
    NetworkMgr:runWhenOnline(function()
        callback_ran = true
        -- runWhenOnline calls back immediately when the device is already
        -- online, so reuse the popup and avoid an extra e-ink refresh. If
        -- KOReader had to connect first, repaint a fresh popup for HTTP work.
        local online_progress = progress
        if progress_closed then online_progress = showLookupProgress() end
        afterLookupProgress(function()
            runLookupSafely(word, online_progress, function()
                self:_lookupOnlineAndShow(word, online_progress)
            end)
        end)
    end)
    -- KOReader owns any Wi-Fi prompt. Do not leave our non-dismissible popup
    -- behind if the user cancels and the callback is never invoked.
    if not callback_ran then
        progress_closed = true
        closeLookupProgress(progress)
    end
end

function Pronunciation:lookupAndShow(word)
    word = trim(word)
    if word == "" then return end
    local progress = showLookupProgress()
    afterLookupProgress(function()
        runLookupSafely(word, progress, function()
            self:_lookupAndShow(word, progress)
        end)
    end)
end

function Pronunciation:editOverride(word)
    word = normalizeWord(word)
    if word == "" then return end
    local existing = type(self.overrides[word]) == "table"
        and self.overrides[word] or {}
    local dialog
    if not InputDialog then InputDialog = require("ui/widget/inputdialog") end
    dialog = InputDialog:new{
        title = _("Pronunciation override") .. ": " .. word,
        input = (existing.ipa or "") .. "\n" .. (existing.simple or ""),
        input_hint = _("/IPA/ on line 1\nReadable pronunciation on line 2"),
        allow_newline = true,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Delete"),
                callback = function()
                    self.overrides[word] = nil
                    self.settings:saveSetting("overrides", self.overrides)
                    self.settings:flush()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                callback = function()
                    local text = dialog:getInputText() or ""
                    local ipa, simple = text:match("([^\n]*)\n?(.*)")
                    ipa, simple = trim(ipa), trim(simple)
                    if ipa ~= "" or simple ~= "" then
                        self.overrides[word] = {
                            ipa = ipa ~= "" and wrapIpa(ipa) or nil,
                            simple = simple ~= "" and simple or nil,
                        }
                    else
                        self.overrides[word] = nil
                    end
                    self.settings:saveSetting("overrides", self.overrides)
                    self.settings:flush()
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return Pronunciation
