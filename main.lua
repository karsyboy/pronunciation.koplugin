local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

-- Keep database, AI networking, and dialog modules out of the plugin's startup
-- footprint. They are loaded only when the corresponding feature is used.
local AI, DictQuickLookup, InfoMessage, InputDialog, LFS, NetworkMgr, SQ3
local TextBoxWidget

local function sqliteModule()
    if not SQ3 then SQ3 = require("lua-ljsqlite3/init") end
    return SQ3
end

local function openDatabase(path)
    return sqliteModule().open(path, "ro")
end

local function aiModule(plugin)
    if not AI then AI = dofile((plugin and plugin.path or ".") .. "/ai.lua") end
    return AI
end

local function newInfoMessage(options)
    if not InfoMessage then InfoMessage = require("ui/widget/infomessage") end
    return InfoMessage:new(options)
end

local function showLookupProgress(dismissable)
    local progress = newInfoMessage{
        text = _("Looking up pronunciation…"),
        dismissable = dismissable == true,
        show_icon = false,
    }
    UIManager:show(progress)
    -- Make the message visible before database, G2P, or subprocess work starts.
    -- Guard the repaint API for compatibility with older KOReader builds.
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

local function runInTrapper(callback)
    local ok, Trapper = pcall(require, "ui/trapper")
    if ok and Trapper and type(Trapper.wrap) == "function" then
        Trapper:wrap(callback)
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

local PLUGIN_VERSION = "0.9.0"
local DICTIONARY_BUTTON_ID = "pronunciation_lookup"
local CACHE_VERSION = 8
local GENERATOR_VERSION = 5
local GENERATED_CACHE_LIMIT = 128
local GENERATED_CACHE_PREFIX = "generator:" .. GENERATOR_VERSION .. "|"

local Pronunciation = WidgetContainer:extend{
    name = "pronunciation",
    is_doc_only = true,
}

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
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
    return (word:gsub("^[%p%s]+", ""):gsub("[%p%s]+$", ""))
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

    local ignorable = {
        ["."] = true, ["-"] = true, [" "] = true,
        ["("] = true, [")"] = true, ["|"] = true, ["‿"] = true,
        ["ː"] = true, ["ˑ"] = true, ["̆"] = true,
        ["ʰ"] = true, ["ʲ"] = true, ["ʷ"] = true,
        ["ᵊ"] = true, ["ⁿ"] = true, ["ʼ"] = true,
        ["̚"] = true, ["̠"] = true, ["̪"] = true, ["̻"] = true,
        ["̝"] = true, ["̞"] = true, ["̯"] = true, ["̤"] = true,
        ["̥"] = true, ["̬"] = true, ["̃"] = true,
    }

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
                -- Known separators, optional-phone markers, length marks, and
                -- phonetic diacritics do not contribute a readable segment.
                -- Any other symbol is a phone we do not understand; failing
                -- the whole conversion is safer than displaying a plausible
                -- but materially incomplete pronunciation.
                if not ignorable[character] then return nil end
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
    if not phones or #phones == 0 then return nil end

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
    local has_stress = false
    for _, phone in ipairs(phones) do
        if phone.stress then has_stress = true break end
    end
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
        if stress == 1 or (not has_stress and s == 1) then
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
    local english = result and (result.language_code == "en"
        or (not result.language_code
            and (not result.language or result.language == "English")))
    if english and (not result.simple or result.simple == "") and result.ipa then
        result.simple = readableFromIpa(result.ipa)
        result.simple_approx = result.simple ~= nil
    end
    return result
end

local function ensureReadables(results)
    for _, result in ipairs(results or {}) do ensureReadable(result) end
    return results
end

local normalizeGeneratedIpa = wrapIpa

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

local function readPackMetadata(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local metadata = {}
    for line in file:lines() do
        local key, value = line:match("^([^\t]+)\t(.*)$")
        if key and value then metadata[key] = value end
    end
    file:close()
    local code = metadata.language_code
    local name = metadata.language_name
    if not code or not code:match("^[a-z][a-z][a-z]?$") or not name
            or name == "" then return nil end
    local aliases = {}
    for alias in (metadata.aliases or code):gmatch("[^,]+") do
        local normalized_alias = normalizeLanguageKey(alias)
        if normalized_alias ~= "" then aliases[#aliases + 1] = normalized_alias end
    end
    return {
        code = code,
        name = name,
        aliases = aliases,
        readable_converter = metadata.readable_converter,
        readable_sha256 = metadata.readable_sha256,
        g2p_model = metadata.g2p_model,
        g2p_sha256 = metadata.g2p_sha256,
    }
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

function Pronunciation:discoverLanguagePacks(force)
    if self.language_packs and not force then return self.language_packs end
    local packs = {}
    local data_path = self.data_path or (self.path .. "/data")
    if not LFS then
        local ok, module = pcall(require, "lfs")
        LFS = ok and module or false
    end
    local function add(code)
        if packs[code] then return end
        local directory = data_path .. "/" .. code
        local metadata = readPackMetadata(directory .. "/pack.tsv")
        local database_path = directory .. "/pronunciations.sqlite3"
        if metadata and metadata.code == code and fileExists(database_path) then
            metadata.directory = directory
            metadata.path = database_path
            -- Pack assets have fixed names. Never follow a malformed sidecar
            -- path into another language directory.
            if (not metadata.readable_converter
                    or metadata.readable_converter == "readable.tsv")
                    and type(metadata.readable_sha256) == "string"
                    and metadata.readable_sha256:match("^[0-9a-f]+$")
                    and #metadata.readable_sha256 == 64 then
                local readable_path = directory .. "/readable.tsv"
                if fileExists(readable_path) then
                    metadata.readable_path = readable_path
                end
            end
            if (not metadata.g2p_model or metadata.g2p_model == "g2p.bin")
                    and type(metadata.g2p_sha256) == "string"
                    and metadata.g2p_sha256:match("^[0-9a-f]+$")
                    and #metadata.g2p_sha256 == 64 then
                local g2p_path = directory .. "/g2p.bin"
                if fileExists(g2p_path) then metadata.g2p_path = g2p_path end
            end
            packs[code] = metadata
        end
    end
    if LFS and type(LFS.dir) == "function" then
        local ok, error_message = pcall(function()
            local iterator, state = LFS.dir(data_path)
            for entry in iterator, state do
                if entry:match("^[a-z][a-z][a-z]?$") then add(entry) end
            end
        end)
        if not ok then
            logger.warn("Pronunciation: language-pack discovery failed:",
                error_message)
        end
    end
    -- English is the bundled baseline even on stripped-down Lua builds
    -- without LuaFileSystem. Optional pack discovery requires KOReader's
    -- normal lfs module.
    add("en")
    local aliases = {}
    for code, pack in pairs(packs) do
        aliases[code] = code
        for _, alias in ipairs(pack.aliases) do aliases[alias] = code end
    end
    self.language_packs = packs
    self.language_pack_aliases = aliases
    return packs
end

function Pronunciation:normalizePronunciationLanguage(value)
    local key = normalizeLanguageKey(value)
    if key == "" then return nil end
    self:discoverLanguagePacks()
    local aliases = self.language_pack_aliases or {}
    local code = aliases[key]
    if code then return code end
    local base = key:match("^([a-z][a-z][a-z]?)%-")
    return base and aliases[base] or nil
end

function Pronunciation:documentLanguageValues()
    local document = self.ui and self.ui.document
    if not document or type(document.getProps) ~= "function" then return {} end
    local ok, properties = pcall(document.getProps, document)
    if not ok or type(properties) ~= "table"
            or type(properties.language) ~= "string" then return {} end
    local values = {}
    for value in properties.language:gmatch("[^,;]+") do
        values[#values + 1] = value
    end
    return values
end

function Pronunciation:documentPronunciationLanguage()
    for _, value in ipairs(self:documentLanguageValues()) do
        local code = self:normalizePronunciationLanguage(value)
        if code then return code end
    end
end

function Pronunciation:selectedLanguagePack()
    local packs = self:discoverLanguagePacks()
    local code
    if self.pronunciation_language
            and self.pronunciation_language ~= "auto" then
        code = self:normalizePronunciationLanguage(self.pronunciation_language)
    else
        code = self:documentPronunciationLanguage()
    end
    return packs[code] or packs.en
end

function Pronunciation:installedLanguagePacks()
    local packs = self:discoverLanguagePacks(true)
    local ordered = {}
    for _, pack in pairs(packs) do ordered[#ordered + 1] = pack end
    table.sort(ordered, function(left, right)
        if left.name ~= right.name then return left.name < right.name end
        return left.code < right.code
    end)
    return ordered
end

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
    return (phone:gsub("[012]$", ""))
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

local G2P3_HEADER_SIZE = 30
local G2P4_HEADER_SIZE = 32
local G2P_STATE_RECORD_SIZE = 2
local G2P_RANK_RECORD_SIZE = 3
local G2P_INFINITE_FINAL = 65535
local G2P_PACKED_LIMIT = 16777216
local G2P_STATE_OFFSET_BLOCK = 256
local G2P_FINAL_RANK_BLOCK = 256
local G2P_MAX_INPUTS = 64
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

-- MFA/Pynini graphs are repacked into fixed-width records. Only the selected
-- language's index is retained; arc blocks continue to be read lazily.
function Pronunciation:_loadG2pModel(pack)
    if not pack or not pack.g2p_path then return nil end
    self.g2p_models = self.g2p_models or {}
    if self.g2p_models[pack.code] ~= nil then
        return self.g2p_models[pack.code] or nil
    end

    local model_path = pack.g2p_path
    local handle = io.open(model_path, "rb")
    if not handle then
        self.g2p_models[pack.code] = false
        return nil
    end

    local magic = handle:read(8)
    local version = magic == "KPG2P3\0\0" and 3
        or (magic == "KPG2P4\0\0" and 4 or nil)
    local header_size = version == 3 and G2P3_HEADER_SIZE or G2P4_HEADER_SIZE
    local rest = version and handle:read(header_size - 8)
    local header = rest and magic .. rest
    if not version or not rest or #header ~= header_size then
        handle:close()
        logger.warn("Pronunciation: invalid G2P model header for", pack.code)
        self.g2p_models[pack.code] = false
        return nil
    end

    local state_count = readLittleEndian32(header, 9)
    local arc_count = readLittleEndian32(header, 13)
    local start_state = readLittleEndian32(header, 17)
    local weight_scale = readLittleEndian16(header, 21)
    local phone_count = version == 3 and header:byte(23)
        or readLittleEndian16(header, 23)
    local state_record_size = header:byte(version == 3 and 24 or 25)
    local arc_record_size = header:byte(version == 3 and 25 or 26)
    local output_format = version == 3 and 1 or header:byte(27)
    local reserved = header:byte(version == 3 and 26 or 28)
    local final_count = readLittleEndian32(header, version == 3 and 27 or 29)
    local expected_arc_size = version == 3 and 6 or 10
    if not state_count or state_count == 0 or not arc_count or arc_count == 0
            or state_count >= G2P_PACKED_LIMIT
            or arc_count >= G2P_PACKED_LIMIT
            or not start_state or start_state >= state_count
            or not weight_scale or weight_scale == 0 or not phone_count
            or phone_count == 0
            or state_record_size ~= G2P_STATE_RECORD_SIZE
            or arc_record_size ~= expected_arc_size
            or (output_format ~= 1 and output_format ~= 2)
            or reserved ~= 0
            or not final_count or final_count > state_count then
        handle:close()
        logger.warn("Pronunciation: unsupported G2P model for", pack.code)
        self.g2p_models[pack.code] = false
        return nil
    end

    local phone_table = {}
    for index = 1, phone_count do
        local length_data = handle:read(version == 3 and 1 or 2)
        local length = length_data and (version == 3
            and length_data:byte(1) or readLittleEndian16(length_data, 1))
        local phone = length and handle:read(length)
        if not phone or #phone ~= length or length == 0 then
            handle:close()
            logger.warn("Pronunciation: invalid G2P phone table for", pack.code)
            self.g2p_models[pack.code] = false
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
        logger.warn("Pronunciation: G2P model is truncated for", pack.code)
        self.g2p_models[pack.code] = false
        return nil
    end

    self.g2p_models[pack.code] = {
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
        arc_record_size = arc_record_size,
        output_format = output_format,
        version = version,
        language_code = pack.code,
    }
    return self.g2p_models[pack.code]
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

local function utf8Codepoint(character)
    local first, second, third, fourth = character:byte(1, 4)
    if not first then return nil end
    if first < 128 then return first end
    if first < 224 and second then return (first - 192) * 64 + second - 128 end
    if first < 240 and second and third then
        return (first - 224) * 4096 + (second - 128) * 64 + third - 128
    end
    if first < 245 and second and third and fourth then
        return (first - 240) * 262144 + (second - 128) * 4096
            + (third - 128) * 64 + fourth - 128
    end
end

local function spellingInputs(word, legacy_english)
    local spelling = legacy_english and foldEnglishSpelling(word)
        or normalizeWord(word)
    if not spelling then return nil end
    local inputs = {}
    local position = 1
    while position <= #spelling do
        local character = nextUtf8Character(spelling, position)
        if not character then return nil end
        if character ~= "-" and character ~= " " then
            local codepoint = utf8Codepoint(character)
            if not codepoint then return nil end
            inputs[#inputs + 1] = codepoint
        end
        position = position + #character
    end
    return #inputs > 0 and inputs or nil
end

function Pronunciation:_g2pPhones(pack, word)
    local model = self:_loadG2pModel(pack)
    local inputs = model and spellingInputs(word, pack.code == "en")
    if not model or not inputs or #inputs > G2P_MAX_INPUTS then return nil end

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
                    + first_arc * model.arc_record_size) then
            decode_failed = true
            return
        end
        local data = handle:read(arc_count * model.arc_record_size)
        if not data or #data ~= arc_count * model.arc_record_size then
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
        local at_end = input_position == #inputs
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
        local wanted = inputs[input_position + 1]
        for position = 1, #arcs, model.arc_record_size do
            local input_label, output_label, weight, next_state
            if model.version == 3 then
                local packed_input = arcs:byte(position)
                local input_code = packed_input % 32
                input_label = input_code == 0 and 0
                    or (input_code == 1 and 39 or input_code + 95)
                local packed_output = arcs:byte(position + 1)
                output_label = packed_output % 128
                weight = readSignedLittleEndian16(arcs, position + 2)
                local next_state_low = readLittleEndian16(arcs, position + 4)
                next_state = next_state_low and next_state_low
                    + (math.floor(packed_input / 32)
                        + math.floor(packed_output / 128) * 8) * 65536
            else
                input_label = readLittleEndian24(arcs, position)
                output_label = readLittleEndian16(arcs, position + 3)
                weight = readSignedLittleEndian16(arcs, position + 5)
                next_state = readLittleEndian24(arcs, position + 7)
            end
            if input_label == 0 or input_label == wanted then
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
                    predecessors[next_key] = key * 65536 + output_label
                    relaxations = relaxations + 1
                    if relaxations > G2P_MAX_RELAXATIONS then
                        logger.warn("Pronunciation: G2P decode limit exceeded for",
                            pack.code)
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
        local predecessor = predecessors[key]
        if not predecessor then return nil end
        local output_label = predecessor % 65536
        if output_label ~= 0 then
            output[#output + 1] = model.phone_table[output_label]
        end
        key = math.floor(predecessor / 65536)
        path_steps = path_steps + 1
        if path_steps > G2P_MAX_RELAXATIONS then return nil end
    end
    if #output == 0 then return nil end
    for left = 1, math.floor(#output / 2) do
        local right = #output - left + 1
        output[left], output[right] = output[right], output[left]
    end
    return output, model.output_format
end

function Pronunciation:_readableConverter(pack)
    self.readable_converters = self.readable_converters or {}
    if not pack or not pack.readable_path then return nil end
    if self.readable_converters[pack.code] ~= nil then
        return self.readable_converters[pack.code] or nil
    end
    local file = io.open(pack.readable_path, "r")
    if not file then
        self.readable_converters[pack.code] = false
        return nil
    end
    local converter = {}
    local header = file:read("*l")
    if header ~= "ipa\treadable" then
        file:close()
        logger.warn("Pronunciation: invalid readable converter for", pack.code)
        self.readable_converters[pack.code] = false
        return nil
    end
    for line in file:lines() do
        local ipa, readable = line:match("^([^\t]+)\t(.*)$")
        if not ipa or readable == "" or converter[ipa] then
            file:close()
            logger.warn("Pronunciation: invalid readable converter for", pack.code)
            self.readable_converters[pack.code] = false
            return nil
        end
        converter[ipa] = readable
    end
    file:close()
    self.readable_converters[pack.code] = converter
    return converter
end

function Pronunciation:_readableFromPhones(pack, phones)
    local converter = self:_readableConverter(pack)
    if not converter then return nil end
    local chunks = {}
    for _, original in ipairs(phones or {}) do
        local phone = original
        local stressed = phone:find("ˈ", 1, true) or phone:find("ˌ", 1, true)
        phone = phone:gsub("ˈ", ""):gsub("ˌ", "")
        local readable = converter[phone]
        if not readable then return nil end
        if stressed and #chunks > 0 then chunks[#chunks + 1] = "-" end
        chunks[#chunks + 1] = readable
    end
    local result = table.concat(chunks):gsub("%-+", "-")
    return result ~= "" and result or nil
end

function Pronunciation:_readableFromPackIpa(pack, ipa)
    local converter = self:_readableConverter(pack)
    local core = stripIpaWrappers(ipa)
    if not converter or core == "" then return nil end
    local chunks = {}
    local position = 1
    while position <= #core do
        local marker = core:sub(position, position + 2)
        if marker == "ˈ" or marker == "ˌ" then
            if #chunks > 0 then chunks[#chunks + 1] = "-" end
            position = position + #marker
        else
            local best_ipa, best_readable
            for source, readable in pairs(converter) do
                if #source > (best_ipa and #best_ipa or 0)
                        and core:sub(position, position + #source - 1) == source then
                    best_ipa, best_readable = source, readable
                end
            end
            if best_ipa then
                chunks[#chunks + 1] = best_readable
                position = position + #best_ipa
            else
                local character = nextUtf8Character(core, position)
                if not character then return nil end
                if character ~= "." and character ~= "-"
                        and character ~= " " and character ~= "ː"
                        and character ~= "(" and character ~= ")" then
                    return nil
                end
                position = position + #character
            end
        end
    end
    local result = table.concat(chunks):gsub("%-+", "-")
        :gsub("^%-", ""):gsub("%-$", "")
    return result ~= "" and result or nil
end

function Pronunciation:generationPack()
    local selected = self:selectedLanguagePack()
    if selected and selected.g2p_path then return selected end
end

function Pronunciation:generateLocalPronunciations(word)
    if self.generated_mode ~= "local" then return nil end
    local pack = self:generationPack()
    local phones, output_format = self:_g2pPhones(pack, word)
    if not phones then return nil end
    local ipa = output_format == 1 and arpabetPhonesToIpa(phones)
        or wrapIpa(table.concat(phones))
    ipa = normalizeGeneratedIpa(ipa)
    if not ipa then return nil end
    local simple = output_format == 2
        and self:_readableFromPhones(pack, phones) or nil
    if not simple and pack.code == "en" then simple = readableFromIpa(ipa) end
    return {{
        ipa = ipa,
        arpabet = output_format == 1 and table.concat(phones, " ") or nil,
        simple = simple,
        simple_approx = simple ~= nil,
        language_code = pack.code,
        language = pack.name,
        region = pack.code == "en" and "US" or nil,
        source = "MFA/Pynini " .. pack.name .. " G2P",
        confidence = 45,
        generated = true,
    }}
end

function Pronunciation:localGenerationCacheKey(word)
    local pack = self:generationPack()
    local pack_code = pack and pack.code or "none"
    local model_hash = pack and pack.g2p_sha256 or "none"
    local readable_hash = pack and pack.readable_sha256 or "none"
    return "generator:" .. GENERATOR_VERSION .. "|mode:local"
        .. "|pack:" .. pack_code
        .. "|model:" .. model_hash
        .. "|readable:" .. readable_hash
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

local function pruneGeneratedCache(cache, protected_key)
    return pruneResultCache(cache, GENERATED_CACHE_LIMIT, protected_key,
        GENERATED_CACHE_PREFIX)
end

function Pronunciation:init()
    self.data_path = self.path .. "/data"
    self.language_packs = nil
    self.language_pack_aliases = nil
    self.g2p_models = {}
    self.readable_converters = {}
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/pronunciation.lua")
    self.overrides = self.settings:readSetting("overrides", {})
    self.generated_cache = self.settings:readSetting("generated_cache", {})
    if type(self.overrides) ~= "table" then self.overrides = {} end
    if type(self.generated_cache) ~= "table" then self.generated_cache = {} end
    local settings_changed = false
    self.generated_mode = self.settings:readSetting("generated_mode")
    if self.generated_mode ~= "off" and self.generated_mode ~= "local"
            and self.generated_mode ~= "ai" then
        -- The former generated-fallback switch controlled local G2P. Preserve
        -- that intent while removing the unrelated online-fallback setting.
        self.generated_mode = self.settings:readSetting(
            "generated_fallback", true) and "local" or "off"
        self.settings:saveSetting("generated_mode", self.generated_mode)
        settings_changed = true
    end
    local ai = aiModule(self)
    self.ai_available_models = {}
    self.ai_provider_configs = ai.normalizeConfigs(
        self.settings:readSetting("ai_provider_configs", {}))
    self.ai_selected_providers = self.settings:readSetting(
        "ai_selected_providers", {})
    if type(self.ai_selected_providers) ~= "table" then
        self.ai_selected_providers = {}
    end
    if type(self.settings.delSetting) == "function" then
        for _, key in ipairs({
            "online_fallback", "generated_fallback", "cache",
        }) do
            if self.settings:readSetting(key) ~= nil then
                self.settings:delSetting(key)
                settings_changed = true
            end
        end
    end
    self.pronunciation_language = self.settings:readSetting(
        "pronunciation_language", "auto")
    if type(self.pronunciation_language) ~= "string"
            or self.pronunciation_language == "" then
        self.pronunciation_language = "auto"
    end
    -- Cache v8 removes the former online-source cache and gives Local and AI
    -- generation distinct, language-aware identities.
    if self.settings:readSetting("cache_version") ~= CACHE_VERSION then
        self.generated_cache = {}
        self.settings:saveSetting("generated_cache", self.generated_cache)
        self.settings:saveSetting("cache_version", CACHE_VERSION)
        self.settings:flush()
    else
        -- Old generator formats are never reused, and generated entries can
        -- always be recreated. Keep the recoverable cache bounded so
        -- pronunciation.lua cannot grow indefinitely on long-lived devices.
        local generated_changed = pruneGeneratedCache(self.generated_cache)
        if generated_changed then
            self.settings:saveSetting("generated_cache", self.generated_cache)
        end
        if generated_changed or settings_changed then self.settings:flush() end
    end

    self.ui.menu:registerToMainMenu(self)
    self:registerDictionaryButton()
end

function Pronunciation:_dictionaryButtonSpec()
    return {
        id = DICTIONARY_BUTTON_ID,
        text = _("Pronunciation"),
        -- Conditional buttons are appended even when a user has an older saved layout.
        conditional = true,
        row_group = "pronunciation",
        show_func = function(dict_popup)
            local dictionary = dict_popup and dict_popup.ui
                and dict_popup.ui.dictionary
                or (self.ui and self.ui.dictionary)
            self:_removeStaleDictionaryButtonLayout(dictionary)
            return not dict_popup or not dict_popup.is_wiki_fullpage
        end,
        callback = function(dict_popup)
            self:lookupAndShow(popupQueryWord(dict_popup))
        end,
        hold_callback = function(dict_popup)
            self:editOverride(popupQueryWord(dict_popup))
        end,
    }
end

local function removeValue(values, target)
    if type(values) ~= "table" then return false end
    local changed = false
    for index = #values, 1, -1 do
        if values[index] == target then
            table.remove(values, index)
            changed = true
        end
    end
    return changed
end

local function removeButtonFromLayout(layout, button_id, row_count)
    if type(layout) ~= "table" then return false end
    local changed = false
    for row_index = #layout, 1, -1 do
        local row = layout[row_index]
        local row_changed = removeValue(row, button_id)
        if row_changed then
            changed = true
            if #row == 0 then
                table.remove(layout, row_index)
                if type(row_count) == "table" then
                    table.remove(row_count, row_index)
                end
            end
        end
    end
    return changed
end

function Pronunciation:_removeStaleDictionaryButtonLayout(dictionary)
    -- Early builds of KOReader's modern button API could append conditional
    -- rows directly to default_layout. If that contaminated layout was then
    -- customized, the transient button ID was also saved in dict_button_config.
    -- Modern KOReader appends the conditional row again at runtime, displaying
    -- both copies, so remove only the stale persistent occurrences.
    removeButtonFromLayout(dictionary and dictionary.default_layout,
        DICTIONARY_BUTTON_ID)

    local reader_settings = rawget(_G, "G_reader_settings")
    if not reader_settings
            or type(reader_settings.readSetting) ~= "function"
            or type(reader_settings.saveSetting) ~= "function" then
        return
    end
    local config = reader_settings:readSetting("dict_button_config")
    if type(config) ~= "table" then return end

    local changed = removeButtonFromLayout(config.layout,
        DICTIONARY_BUTTON_ID, config.row_count)
    if removeValue(config.order, DICTIONARY_BUTTON_ID) then
        changed = true
    end
    if changed then
        reader_settings:saveSetting("dict_button_config", config)
    end
end

function Pronunciation:registerDictionaryButton()
    local dictionary = self.ui and self.ui.dictionary
    if dictionary and type(dictionary.addToDictButtons) == "function" then
        self.uses_modern_dictionary_buttons = true
        self:_removeStaleDictionaryButtonLayout(dictionary)
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
            or containsButton(buttons, DICTIONARY_BUTTON_ID) then return end
    table.insert(buttons, 1, {{
        id = DICTIONARY_BUTTON_ID,
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

function Pronunciation:onShowPronunciationLookup(selection)
    if not InputDialog then InputDialog = require("ui/widget/inputdialog") end
    local dialog
    dialog = InputDialog:new{
        title = _("Enter a word or phrase to look up"),
        input = selection or "",
        input_type = "text",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Look up pronunciation"),
                is_enter_default = true,
                callback = function()
                    local word = dialog:getInputText() or ""
                    if trim(word) == "" then return end
                    UIManager:close(dialog)
                    self:lookupAndShow(word)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

local function updateTouchMenu(touchmenu_instance)
    if touchmenu_instance
            and type(touchmenu_instance.updateItems) == "function" then
        touchmenu_instance:updateItems()
    end
end

function Pronunciation:setGeneratedMode(mode)
    if mode ~= "off" and mode ~= "local" and mode ~= "ai" then return end
    self.generated_mode = mode
    self.settings:saveSetting("generated_mode", mode)
    self.settings:flush()
end

function Pronunciation:setAIProviderSelected(provider_id, selected)
    if not aiModule(self).provider(provider_id) then return end
    self.ai_selected_providers[provider_id] = selected == true or nil
    self.settings:saveSetting("ai_selected_providers",
        self.ai_selected_providers)
    self.settings:flush()
end

function Pronunciation:saveAIProviderConfig(provider_id, field, value)
    local config = self.ai_provider_configs[provider_id]
    if not config or (field ~= "api_key" and field ~= "model"
            and field ~= "endpoint" and field ~= "format") then return end
    value = trim(value)
    if field == "format" and value ~= "openai" and value ~= "anthropic" then
        return
    end
    if config[field] ~= value and field ~= "model"
            and self.ai_available_models then
        self.ai_available_models[provider_id] = nil
    end
    config[field] = value
    self.settings:saveSetting("ai_provider_configs", self.ai_provider_configs)
    self.settings:flush()
end

function Pronunciation:showAISettingDialog(provider_id, field, title, hint,
        touchmenu_instance)
    local config = self.ai_provider_configs[provider_id]
    if not config then return false end
    local dialog
    local ok = pcall(function()
        if not InputDialog then
            InputDialog = require("ui/widget/inputdialog")
        end
        dialog = InputDialog:new{
            title = title,
            input = config[field] or "",
            input_hint = hint or "",
            text_type = field == "api_key" and "password" or nil,
            buttons = {{
                {
                    text = _("Cancel"), id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"), is_enter_default = true,
                    callback = function()
                        self:saveAIProviderConfig(provider_id, field,
                            dialog:getInputText() or "")
                        UIManager:close(dialog)
                        updateTouchMenu(touchmenu_instance)
                    end,
                },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end)
    if not ok then
        -- Do not include the exception: widget construction may contain the
        -- current input value, which can be an API key.
        logger.err("Pronunciation: AI setting editor could not be opened")
        if dialog then pcall(UIManager.close, UIManager, dialog) end
        UIManager:show(newInfoMessage{
            text = _("Could not open the AI setting editor. Restart KOReader and try again."),
        })
        return false
    end
    return true
end

function Pronunciation:_populateAIModelMenu(items, provider_id, provider_name)
    for index = #items, 1, -1 do items[index] = nil end
    items[#items + 1] = {
        text = _("Fetch available models"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:fetchAIModels(provider_id, provider_name, items,
                touchmenu_instance)
        end,
        separator = true,
    }
    items[#items + 1] = {
        text = _("Enter model manually…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showAISettingDialog(provider_id, "model",
                provider_name .. ": " .. _("Model"), nil,
                touchmenu_instance)
        end,
    }

    local config = self.ai_provider_configs[provider_id] or {}
    local current = trim(config.model)
    local models = self.ai_available_models
        and self.ai_available_models[provider_id] or {}
    local ordered, seen = {}, {}
    if current ~= "" then
        ordered[#ordered + 1] = current
        seen[current] = true
    end
    for _, model in ipairs(models) do
        if type(model) == "string" and not seen[model] then
            seen[model] = true
            ordered[#ordered + 1] = model
        end
    end
    for _, model in ipairs(ordered) do
        local model_id = model
        items[#items + 1] = {
            text = model_id,
            checked_func = function()
                local saved = self.ai_provider_configs[provider_id]
                return saved and saved.model == model_id
            end,
            callback = function(touchmenu_instance)
                self:saveAIProviderConfig(provider_id, "model", model_id)
                updateTouchMenu(touchmenu_instance)
            end,
        }
    end
end

function Pronunciation:aiModelMenuItems(provider_id, provider_name)
    local items = {}
    self:_populateAIModelMenu(items, provider_id, provider_name)
    return items
end

function Pronunciation:fetchAIModels(provider_id, provider_name, menu_items,
        touchmenu_instance)
    local ai = aiModule(self)
    local config = self.ai_provider_configs[provider_id]
    if not ai.buildModelsRequest(provider_id, config) then
        UIManager:show(newInfoMessage{
            text = provider_name .. ": "
                .. _("configure the API key and endpoint first"),
        })
        return
    end
    if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
    NetworkMgr:runWhenOnline(function()
        local progress = newInfoMessage{
            text = provider_name .. ": " .. _("fetching available models…"),
            dismissable = true,
            show_icon = false,
        }
        UIManager:show(progress)
        if type(UIManager.forceRePaint) == "function" then
            UIManager:forceRePaint()
        end
        afterLookupProgress(function()
            runInTrapper(function()
                local request_function
                if type(self.ai_models_request) == "function" then
                    request_function = function(request, request_progress)
                        return self:ai_models_request(request, request_progress)
                    end
                end
                local ok, models, error_message = pcall(ai.listModels,
                    provider_id, config, progress, request_function)
                UIManager:close(progress)
                if not ok then
                    logger.err("Pronunciation: model discovery failed for",
                        provider_name)
                    error_message = "request failed"
                    models = nil
                end
                if not models then
                    UIManager:show(newInfoMessage{
                        text = provider_name .. ": "
                            .. (error_message or _("request failed")),
                    })
                    return
                end
                self.ai_available_models = self.ai_available_models or {}
                self.ai_available_models[provider_id] = models
                self:_populateAIModelMenu(menu_items, provider_id,
                    provider_name)
                updateTouchMenu(touchmenu_instance)
                UIManager:show(newInfoMessage{
                    text = provider_name .. ": " .. tostring(#models)
                        .. " " .. _("models available"),
                    timeout = 3,
                })
            end)
        end)
    end)
end

function Pronunciation:addToMainMenu(menu_items)
    local pronunciation_language_items = {
        {
            text = _("Auto (book language)"),
            checked_func = function()
                return self.pronunciation_language == "auto"
            end,
            callback = function() self:setPronunciationLanguage("auto") end,
        },
    }
    for _, pack in ipairs(self:installedLanguagePacks()) do
        pronunciation_language_items[#pronunciation_language_items + 1] = {
            text = pack.name,
            checked_func = function()
                return self.pronunciation_language == pack.code
            end,
            callback = function() self:setPronunciationLanguage(pack.code) end,
        }
    end
    menu_items.pronunciation_lookup = {
        sorting_hint = "search",
        text = _("Pronunciation lookup"),
        callback = function() self:onShowPronunciationLookup() end,
    }

    local generated_mode_items = {}
    for _, choice in ipairs({
        { id = "off", name = _("Off") },
        { id = "local", name = _("Local") },
        { id = "ai", name = _("AI") },
    }) do
        local mode, name = choice.id, choice.name
        generated_mode_items[#generated_mode_items + 1] = {
            text = name,
            checked_func = function() return self.generated_mode == mode end,
            callback = function() self:setGeneratedMode(mode) end,
        }
    end

    local provider_selection_items = {}
    local provider_configuration_items = {}
    -- Do not name the discarded index `_`: callbacks below need the gettext
    -- `_` upvalue after this function returns. Capturing the numeric loop index
    -- here caused KOReader to crash as soon as a provider submenu was opened.
    local ai_providers = aiModule(self).providers
    for provider_index = 1, #ai_providers do
        local provider = ai_providers[provider_index]
        local provider_id, provider_name = provider.id, provider.name
        provider_selection_items[#provider_selection_items + 1] = {
            text = provider_name,
            checked_func = function()
                return self.ai_selected_providers[provider_id] == true
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:setAIProviderSelected(provider_id,
                    self.ai_selected_providers[provider_id] ~= true)
                updateTouchMenu(touchmenu_instance)
            end,
        }
        local config_items = {
            {
                text_func = function()
                    local config = self.ai_provider_configs[provider_id] or {}
                    local key = config.api_key or ""
                    return _("API key") .. ": "
                        .. (key ~= "" and _("configured") or _("not set"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showAISettingDialog(provider_id, "api_key",
                        provider_name .. ": " .. _("API key"), nil,
                        touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    local config = self.ai_provider_configs[provider_id] or {}
                    return _("Model") .. ": "
                        .. (config.model or "")
                end,
                sub_item_table_func = function()
                    return self:aiModelMenuItems(provider_id, provider_name)
                end,
            },
        }
        if provider_id == "custom1" or provider_id == "custom2" then
            config_items[#config_items + 1] = {
                text_func = function()
                    local config = self.ai_provider_configs[provider_id] or {}
                    return _("Endpoint") .. ": "
                        .. (config.endpoint or "")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showAISettingDialog(provider_id, "endpoint",
                        provider_name .. ": " .. _("Endpoint"),
                        "https://…/v1/chat/completions", touchmenu_instance)
                end,
            }
            config_items[#config_items + 1] = {
                text_func = function()
                    return _("API format") .. ": "
                        .. self.ai_provider_configs[provider_id].format
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local format = self.ai_provider_configs[provider_id].format
                    self:saveAIProviderConfig(provider_id, "format",
                        format == "openai" and "anthropic" or "openai")
                    updateTouchMenu(touchmenu_instance)
                end,
            }
        end
        provider_configuration_items[#provider_configuration_items + 1] = {
            text = provider_name,
            sub_item_table = config_items,
        }
    end

    menu_items.pronunciation = {
        sorting_hint = "search_settings",
        text = _("Pronunciation settings"),
        sub_item_table = {
            {
                text_func = function()
                    local labels = {
                        off = _("Off"), ["local"] = _("Local"), ai = _("AI"),
                    }
                    return _("Generated pronunciation") .. ": "
                        .. (labels[self.generated_mode] or _("Off"))
                end,
                sub_item_table = generated_mode_items,
            },
            {
                text = _("AI settings"),
                enabled_func = function() return self.generated_mode == "ai" end,
                sub_item_table = {
                    {
                        text = _("Providers"),
                        sub_item_table = provider_selection_items,
                    },
                    {
                        text = _("API keys and models"),
                        sub_item_table = provider_configuration_items,
                    },
                },
            },
            {
                text_func = function()
                    if self.pronunciation_language == "auto" then
                        return _("Pronunciation language") .. ": " .. _("Auto")
                    end
                    local packs = self:discoverLanguagePacks()
                    local pack = packs[self.pronunciation_language]
                    return _("Pronunciation language") .. ": "
                        .. (pack and pack.name or self.pronunciation_language)
                end,
                sub_item_table = pronunciation_language_items,
            },
            {
                text = _("Clear cached pronunciations"),
                callback = function()
                    self.generated_cache = {}
                    self.settings:saveSetting("generated_cache",
                        self.generated_cache)
                    self.settings:flush()
                end,
            },
            {
                text = _("About pronunciation dictionary"),
                callback = function()
                    UIManager:show(newInfoMessage{
                        text = _("Offline language packs with automatic book-language selection, optional local or AI generation, and personal overrides. Long-press Pronunciation to save an override.")
                            .. "\n\n" .. _("Version") .. ": " .. PLUGIN_VERSION,
                    })
                end,
            },
        },
    }
end

function Pronunciation:setPronunciationLanguage(code)
    if code ~= "auto" then
        code = self:normalizePronunciationLanguage(code)
        if not code then return end
    end
    self.pronunciation_language = code
    self.settings:saveSetting("pronunciation_language", code)
    self.settings:flush()
end

function Pronunciation:getOverride(word)
    local normalized = normalizeWord(word)
    local pack = self:selectedLanguagePack()
    local code = pack and pack.code or "none"
    local overrides = self.overrides or {}
    local override = overrides["language:" .. code .. "|word:" .. normalized]
    -- Pre-language-pack settings were English-only. Preserve those personal
    -- entries for English, but never reuse them in another language.
    if not override and code == "en" then override = overrides[normalized] end
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
    SELECT ipa, arpabet, simple, source, confidence, region, simple_approx,
           language_code, language_name
      FROM pronunciations
     WHERE word = ?
  ORDER BY confidence DESC, source, region, ipa
]]

function Pronunciation:_queryConnection(connection, word, statement, pack)
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
            local row_language = row[8] or (pack and pack.code)
            if not pack or row_language == pack.code then
                rows[#rows + 1] = {
                    ipa = row[1],
                    arpabet = row[2],
                    simple = row[3],
                    source = row[4],
                    confidence = tonumber(row[5]) or 0,
                    region = row[6],
                    language_code = row_language,
                    language = row[9] or (pack and pack.name),
                    simple_approx = tonumber(row[7]) == 1,
                }
            end
        end
        return rows
    end)
    if not ok then
        closeSqlResource(statement)
        return nil, results, nil
    end
    if #results > 0 then
        if pack and pack.code ~= "en" then
            for _, result in ipairs(results) do
                if (not result.simple or result.simple == "") and result.ipa then
                    result.simple = self:_readableFromPackIpa(pack, result.ipa)
                    result.simple_approx = result.simple ~= nil
                end
            end
        end
        ensureReadables(results)
        return results, nil, statement
    end
    return nil, nil, statement
end

function Pronunciation:query(word)
    local pack = self:selectedLanguagePack()
    if not pack then return nil end
    local opened, connection = pcall(openDatabase, pack.path)
    if not opened or not connection then
        logger.err("Pronunciation: database open failed:", connection)
        return nil
    end
    local normalized = normalizeWord(word)
    local results, query_error, statement = self:_queryConnection(connection,
        normalized, nil, pack)
    closeSqlResource(statement)
    closeSqlResource(connection)
    if query_error then
        logger.err("Pronunciation: database lookup failed:", query_error)
    end
    return results
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
    return phones and phones[#phones] and phones[#phones].symbol or nil
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
            local phone = finalPhone(base)
            if (kind == "plural" or kind == "possessive") and phone then
                suffix = pluralSuffix(phone)
            elseif kind == "past" and phone then
                suffix = pastSuffix(phone)
            elseif kind == "ing" and phone then
                suffix = "ɪŋ"
            end
            local ipa = suffix and appendIpa(base.ipa, suffix)
            if ipa then
                results[#results + 1] = {
                    ipa = ipa,
                    simple = readableFromIpa(ipa),
                    simple_approx = true,
                    region = base.region,
                    language_code = base.language_code,
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
    local pack = self:selectedLanguagePack()
    local opened, connection = false, nil
    if pack then opened, connection = pcall(openDatabase, pack.path) end
    if not opened or not connection then
        logger.err("Pronunciation: database open failed:", connection)
        connection = nil
    end
    local statement
    local function queryDatabase(candidate_word)
        if not connection then return nil end
        local rows, query_error, reusable_statement = self:_queryConnection(
            connection, candidate_word, statement, pack)
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

    for _, candidate in ipairs(pack and pack.code == "en"
            and self:candidates(word) or {}) do
        local base = self:getOverride(candidate.word)
            or queryDatabase(candidate.word)
        if base then
            local derived = self:derive(base, candidate.kind, candidate.word)
            if derived then return finish(derived, candidate.word) end
        end
    end
    return finish()
end

local function cachePart(value)
    local escaped = tostring(value or ""):gsub("%%", "%%25")
        :gsub("|", "%%7C"):gsub("[\r\n]", "")
    return escaped
end

local function cacheHash(value)
    local hash = 5381
    value = tostring(value or "")
    for index = 1, #value do
        hash = (hash * 33 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

function Pronunciation:getGeneratedCache(key, expected)
    local cached = (self.generated_cache or {})[key]
    if type(cached) ~= "table" or #cached == 0 then return nil end
    for _, result in ipairs(cached) do
        if type(result) ~= "table" or result.generated ~= true
                or type(result.ipa) ~= "string" or not wrapIpa(result.ipa) then
            return nil
        end
        if result.ai_generated and (type(result.simple) ~= "string"
                or trim(result.simple) == ""
                or type(result.provider_name) ~= "string"
                or result.provider_name == ""
                or type(result.model) ~= "string" or result.model == "") then
            return nil
        end
        if expected then
            for field, value in pairs(expected) do
                if result[field] ~= value then return nil end
            end
        end
    end
    return cached
end

function Pronunciation:saveGeneratedCache(key, results)
    self.generated_cache = self.generated_cache or {}
    self.generated_cache[key] = results
    pruneGeneratedCache(self.generated_cache, key)
    self.settings:saveSetting("generated_cache", self.generated_cache)
    self.settings:saveSetting("cache_version", CACHE_VERSION)
    self.settings:flush()
end

function Pronunciation:aiLanguage()
    if self.pronunciation_language and self.pronunciation_language ~= "auto" then
        local code = self:normalizePronunciationLanguage(
            self.pronunciation_language)
        local definition = code and self:discoverLanguagePacks()[code] or nil
        if definition then
            local prompt_language = definition.code == "en"
                and "English (standard US English)" or definition.name
            return definition.code, prompt_language, definition.code,
                definition.name
        end
        return "manual:none", nil, nil, nil
    end

    -- A book's language tag is reliable metadata even when no matching local
    -- pack is installed. Keep the locale in the cache identity and send it to
    -- the provider, while rejecting free-form metadata that could be mistaken
    -- for an instruction.
    for _, value in ipairs(self:documentLanguageValues()) do
        local key = normalizeLanguageKey(value)
        local is_tag = key:match("^[a-z][a-z]$")
            or key:match("^[a-z][a-z][a-z]$")
            or key:match("^[a-z][a-z][a-z]?%-[a-z0-9%-]+$")
        local known_definition = languageDefinition(nil, key)
        if key ~= "" and #key <= 64 and (is_tag or known_definition) then
            local code = self:normalizePronunciationLanguage(key)
            local definition = (code and self:discoverLanguagePacks()[code])
                or known_definition
            local prompt_language = key
            local language_code = key:match("^([a-z][a-z][a-z]?)")
            local language_name
            if definition then
                language_code = definition.code
                language_name = definition.name
                if definition.code == "en" then
                    prompt_language = "English (standard US English)"
                elseif key == definition.code
                        or key == definition.name:lower() then
                    prompt_language = definition.name
                else
                    prompt_language = definition.name .. " (" .. key .. ")"
                end
            end
            return "auto:" .. key, prompt_language, language_code,
                language_name
        end
    end

    -- Some document backends can normalize a language without exposing the
    -- raw property through getProps(). Preserve that compatibility fallback.
    local code = self:documentPronunciationLanguage()
    local definition = code and self:discoverLanguagePacks()[code] or nil
    if definition then
        local prompt_language = definition.code == "en"
            and "English (standard US English)" or definition.name
        return definition.code, prompt_language, definition.code,
            definition.name
    end
    return "auto:none", nil, nil, nil
end

function Pronunciation:aiGenerationCacheKey(word, language_identity,
        provider_id, model, endpoint_identity)
    return "generator:" .. GENERATOR_VERSION
        .. "|mode:ai|language:" .. cachePart(language_identity)
        .. "|provider:" .. cachePart(provider_id)
        .. "|model:" .. cachePart(model)
        .. "|endpoint:" .. cacheHash(endpoint_identity)
        .. "|word:" .. cachePart(normalizeWord(word))
end

function Pronunciation:format(original, results, matched)
    local lines = { boldHeading(original) }
    if matched and normalizeWord(original) ~= matched then
        lines[#lines + 1] = _("Matched/derived from") .. ": " .. matched
    end
    lines[#lines + 1] = ""
    for index, result in ipairs(results) do
        if result.ai_generated then
            lines[#lines + 1] = _("IPA") .. ": " .. result.ipa
            lines[#lines + 1] = _("Readable") .. ": " .. result.simple
            lines[#lines + 1] = _("Source") .. ": "
                .. result.provider_name .. " (" .. result.model .. ")"
        else
            local location
            if result.language and result.region then
                location = result.region .. " " .. result.language
            else
                location = result.language or result.region
            end
            local qualifiers = {}
            if result.generated then qualifiers[#qualifiers + 1] = _("generated") end
            if location then qualifiers[#qualifiers + 1] = location end
            local qualifier = #qualifiers > 0
                and " (" .. table.concat(qualifiers, "; ") .. ")" or ""
            lines[#lines + 1] = _("IPA") .. qualifier .. ": "
                .. (result.ipa or "—")
            if result.simple and result.simple ~= "" then
                local readable_qualifier = result.simple_approx
                    and " (" .. _("approx.") .. ")" or ""
                lines[#lines + 1] = _("Readable") .. readable_qualifier
                    .. ": " .. result.simple
            end
            if result.source then
                lines[#lines + 1] = _("Source") .. ": " .. result.source
            end
        end
        if index < #results then lines[#lines + 1] = "" end
    end
    return table.concat(lines, "\n")
end

function Pronunciation:lookupCached(word)
    local normalized = normalizeWord(word)
    local results = self:getOverride(normalized)
    if results then return results, normalized end
end

function Pronunciation:localGeneratedForWord(word)
    if self.generated_mode ~= "local" then return nil end
    local cache_key = self:localGenerationCacheKey(word)
    local pack = self:generationPack()
    local expected = {
        generation_mode = "local",
        language_code = pack and pack.code or "none",
    }
    local cached = self:getGeneratedCache(cache_key, expected)
    if cached then return cached end
    local generated = self:generateLocalPronunciations(word)
    if generated then
        for _, result in ipairs(generated) do result.generation_mode = "local" end
        self:saveGeneratedCache(cache_key, generated)
    end
    return generated
end

function Pronunciation:selectedAIProviderIds()
    local selected = {}
    for _, provider in ipairs(aiModule(self).providers) do
        if self.ai_selected_providers[provider.id] == true then
            selected[#selected + 1] = provider.id
        end
    end
    return selected
end

function Pronunciation:aiCacheExpectation(language_identity, provider_id,
        model, endpoint_identity)
    return {
        generation_mode = "ai",
        ai_generated = true,
        language_cache = language_identity,
        provider = provider_id,
        model = model,
        endpoint_cache = cacheHash(endpoint_identity),
    }
end

function Pronunciation:aiNeedsNetwork(word)
    local ai = aiModule(self)
    local language_identity = self:aiLanguage()
    for _, provider_id in ipairs(self:selectedAIProviderIds()) do
        local config = self.ai_provider_configs[provider_id]
        if ai.usableConfig(provider_id, config) then
            local endpoint_identity = config.format .. "|" .. config.endpoint
            local key = self:aiGenerationCacheKey(word, language_identity,
                provider_id, config.model, endpoint_identity)
            if not self:getGeneratedCache(key,
                    self:aiCacheExpectation(language_identity, provider_id,
                        config.model, endpoint_identity)) then
                return true
            end
        end
    end
    return false
end

function Pronunciation:aiGeneratedForWord(word, progress)
    if self.generated_mode ~= "ai" then return nil end
    local ai = aiModule(self)
    local language_identity, prompt_language, language_code, language_name =
        self:aiLanguage()
    local results, errors = {}, {}
    local selected = self:selectedAIProviderIds()
    if #selected == 0 then
        return nil, {
            _("No AI provider selected. Select one in Pronunciation settings → AI settings.")
        }
    end
    for _, provider_id in ipairs(selected) do
        local provider = ai.provider(provider_id)
        local config = self.ai_provider_configs[provider_id]
        if not ai.usableConfig(provider_id, config) then
            errors[#errors + 1] = provider.name .. ": "
                .. _("configure an API key, model, and endpoint if required")
        else
            local endpoint_identity = config.format .. "|" .. config.endpoint
            local key = self:aiGenerationCacheKey(word, language_identity,
                provider_id, config.model, endpoint_identity)
            local expected = self:aiCacheExpectation(language_identity,
                provider_id, config.model, endpoint_identity)
            local cached = self:getGeneratedCache(key, expected)
            if cached then
                results[#results + 1] = cached[1]
            else
                local request_function
                if type(self.ai_request) == "function" then
                    request_function = function(request, request_progress)
                        return self:ai_request(request, request_progress)
                    end
                end
                local generated, error_message = ai.query(provider_id, config,
                    word, prompt_language, progress, request_function)
                if generated then
                    generated.generated = true
                    generated.ai_generated = true
                    generated.generation_mode = "ai"
                    generated.language_cache = language_identity
                    generated.endpoint_cache = cacheHash(endpoint_identity)
                    generated.language_code = language_code
                    generated.language = language_name
                    generated.simple_approx = false
                    generated.source = nil
                    self:saveGeneratedCache(key, { generated })
                    results[#results + 1] = generated
                else
                    errors[#errors + 1] = provider.name .. ": "
                        .. (error_message or _("request failed"))
                    if error_message == "cancelled" then break end
                end
            end
        end
    end
    return #results > 0 and results or nil, errors
end

function Pronunciation:formatAIOutcome(word, results, errors)
    local text
    if results then
        text = self:format(word, results, normalizeWord(word))
    else
        text = word
    end
    if errors and #errors > 0 then
        text = text .. "\n\n" .. table.concat(errors, "\n")
    elseif not results then
        text = text .. "\n\n" .. _("No AI pronunciation was returned.")
    end
    return text
end

function Pronunciation:_lookupAIAndShow(word, progress)
    local results, errors = self:aiGeneratedForWord(normalizeWord(word), progress)
    showLookupMessage(progress, self:formatAIOutcome(word, results, errors))
end

function Pronunciation:_lookupAndShow(word, progress)
    local normalized = normalizeWord(word)
    local results, matched = self:lookupCached(normalized)
    if results then
        showLookupMessage(progress, self:format(word, results, matched))
        return
    end
    results, matched = self:lookupOffline(normalized)
    if results then
        showLookupMessage(progress, self:format(word, results, matched))
        return
    end
    if self.generated_mode == "off" then
        showLookupMessage(progress,
            word .. "\n\n"
                .. _("No sourced pronunciation found. Long-press Pronunciation to add a personal override."))
        return
    elseif self.generated_mode == "local" then
        local generated = self:localGeneratedForWord(normalized)
        if generated then
            showLookupMessage(progress, self:format(word, generated, normalized))
        else
            showLookupMessage(progress,
                word .. "\n\n"
                    .. _("No local pronunciation found. Long-press Pronunciation to add a personal override."))
        end
        return
    end

    local selected = self:selectedAIProviderIds()
    local usable = false
    local ai = aiModule(self)
    for _, provider_id in ipairs(selected) do
        if ai.usableConfig(provider_id,
                self.ai_provider_configs[provider_id]) then
            usable = true
            break
        end
    end
    if #selected == 0 or not usable then
        local _, errors = self:aiGeneratedForWord(normalized, progress)
        showLookupMessage(progress, self:formatAIOutcome(word, nil, errors))
        return
    end

    if not self:aiNeedsNetwork(normalized) then
        self:_lookupAIAndShow(word, progress)
        return
    end

    if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
    local callback_ran = false
    local progress_closed = false
    NetworkMgr:runWhenOnline(function()
        callback_ran = true
        local ai_progress = progress
        if progress_closed then ai_progress = showLookupProgress(true) end
        afterLookupProgress(function()
            runInTrapper(function()
                runLookupSafely(word, ai_progress, function()
                    self:_lookupAIAndShow(word, ai_progress)
                end)
            end)
        end)
    end)
    if not callback_ran then
        progress_closed = true
        closeLookupProgress(progress)
    end
end

function Pronunciation:lookupAndShow(word)
    word = trim(word)
    if word == "" or normalizeWord(word) == "" then return end
    local cached, matched = self:lookupCached(word)
    if cached then
        showLookupMessage(nil, self:format(word, cached, matched))
        return
    end
    local progress = showLookupProgress(self.generated_mode == "ai")
    afterLookupProgress(function()
        runLookupSafely(word, progress, function()
            self:_lookupAndShow(word, progress)
        end)
    end)
end

function Pronunciation:editOverride(word)
    word = normalizeWord(word)
    if word == "" then return end
    local pack = self:selectedLanguagePack()
    local code = pack and pack.code or "none"
    local override_key = "language:" .. code .. "|word:" .. word
    local existing = self.overrides[override_key]
    if type(existing) ~= "table" and code == "en" then
        existing = self.overrides[word]
    end
    if type(existing) ~= "table" then existing = {} end
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
                    self.overrides[override_key] = nil
                    if code == "en" then self.overrides[word] = nil end
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
                        self.overrides[override_key] = {
                            ipa = ipa ~= "" and wrapIpa(ipa) or nil,
                            simple = simple ~= "" and simple or nil,
                        }
                        if code == "en" then self.overrides[word] = nil end
                    else
                        self.overrides[override_key] = nil
                        if code == "en" then self.overrides[word] = nil end
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
