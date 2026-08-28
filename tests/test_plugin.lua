local function preload(name, value)
    package.preload[name] = function() return value end
end

local shown_widget
local UIManager = {
    show = function(_, widget) shown_widget = widget end,
    close = function() end,
}
local NetworkMgr = {
    runWhenOnline = function(_, callback) callback() end,
}

preload("datastorage", {})
preload("ui/widget/infomessage", { new = function(_, value) return value end })
preload("ui/widget/inputdialog", { new = function(_, value) return value end })
preload("json", { decode = function() return {} end })
preload("luasettings", {})
preload("ui/network/manager", NetworkMgr)
local SQ3 = {}
preload("lua-ljsqlite3/init", SQ3)
preload("ui/uimanager", UIManager)
preload("ui/widget/container/widgetcontainer", {
    extend = function(_, value) return value end,
})
local DictQuickLookup = {}
function DictQuickLookup:init()
    local buttons = {}
    if self.tweak_buttons_func then self:tweak_buttons_func(buttons) end
    self.test_buttons = buttons
end
preload("ui/widget/dictquicklookup", DictQuickLookup)
preload("logger", { err = function() end, warn = function() end })
preload("ltn12", { sink = { table = function() return function() end end } })
preload("socket", { skip = function(_, value) return value end })
preload("socket.http", { request = function() return nil, 500 end })
preload("socketutil", {
    set_timeout = function() end,
    reset_timeout = function() end,
})
preload("socket.url", { escape = function(value) return value end })
preload("gettext", function(value) return value end)

local Plugin = dofile("main.lua")
Plugin.path = "."
Plugin.generated_fallback = true

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, message)
    if not value then error(message or "expected a truthy value", 2) end
end

local function hasCandidate(word, expected_word, expected_kind)
    for _, candidate in ipairs(Plugin:candidates(word)) do
        if candidate.word == expected_word and candidate.kind == expected_kind then
            return true
        end
    end
    return false
end

-- Legacy registration must not call a missing modern API.
Plugin.ui = { dictionary = {} }
DictQuickLookup.tweak_buttons_func = function(_, buttons)
    table.insert(buttons, {{ id = "other_plugin" }})
end
local legacy_ok = pcall(function() Plugin:registerDictionaryButton() end)
truthy(legacy_ok, "legacy registration raised an error")
local pre_event_popup = setmetatable({ lookupword = "cat" }, {
    __index = DictQuickLookup,
})
pre_event_popup:init()
equal(#pre_event_popup.test_buttons, 2, "pre-event button row count")
equal(pre_event_popup.test_buttons[1][1].id, "pronunciation_lookup",
    "pre-event button id")
equal(pre_event_popup.test_buttons[2][1].id, "other_plugin",
    "pre-event hook did not chain another plugin")
local legacy_buttons = {}
Plugin:onDictButtonsReady({ lookupword = "cat" }, legacy_buttons)
equal(#legacy_buttons, 1, "legacy button row count")
equal(legacy_buttons[1][1].id, "pronunciation_lookup", "legacy button id")
Plugin:onDictButtonsReady({ lookupword = "cat" }, legacy_buttons)
equal(#legacy_buttons, 1, "legacy event inserted a duplicate button")

-- Buttons use the original query, not a dictionary result/headword. The
-- lookupword-only fallback keeps old/custom KOReader builds working.
local tapped_word
local held_word
local original_lookup_and_show = Plugin.lookupAndShow
local original_edit_override = Plugin.editOverride
Plugin.lookupAndShow = function(_, word) tapped_word = word end
Plugin.editOverride = function(_, word) held_word = word end
pre_event_popup.word = "cats"
pre_event_popup.lookupword = "cat"
pre_event_popup.test_buttons[1][1].callback()
pre_event_popup.test_buttons[1][1].hold_callback()
equal(tapped_word, "cats", "legacy tap used the dictionary headword")
equal(held_word, "cats", "legacy hold used the dictionary headword")
legacy_buttons[1][1].callback()
equal(tapped_word, "cat", "legacy lookupword compatibility fallback failed")

-- Modern registration is conditional, so saved layouts cannot hide the button.
local modern_spec
Plugin.ui = { dictionary = {
    addToDictButtons = function(_, spec) modern_spec = spec end,
} }
Plugin:registerDictionaryButton()
truthy(modern_spec, "modern button was not registered")
equal(modern_spec.id, "pronunciation_lookup", "modern button id")
equal(modern_spec.conditional, true, "modern button must bypass saved layouts")
equal(modern_spec.show_func({ is_wiki_fullpage = false }), true,
    "modern button should appear in dictionary popups")
equal(modern_spec.show_func({ is_wiki_fullpage = true }), false,
    "modern button should not appear in full-page Wikipedia")
modern_spec.callback({ word = "geese", lookupword = "goose" })
modern_spec.hold_callback({ word = "geese", lookupword = "goose" })
equal(tapped_word, "geese", "modern tap used the dictionary headword")
equal(held_word, "geese", "modern hold used the dictionary headword")
Plugin.lookupAndShow = original_lookup_and_show
Plugin.editOverride = original_edit_override
local duplicate_buttons = {}
Plugin:onDictButtonsReady({ lookupword = "cat" }, duplicate_buttons)
equal(#duplicate_buttons, 0, "modern KOReader received a duplicate legacy button")

-- Inflections work from IPA when online results have no ARPABET.
local function derive(ipa, kind)
    return Plugin:derive({{
        ipa = ipa,
        source = "test",
        confidence = 75,
    }}, kind, "base")[1]
end

equal(derive("/kæt/", "plural").ipa, "/kæts/", "voiceless plural")
equal(derive("/dɔɡ/", "plural").ipa, "/dɔɡz/", "voiced plural")
equal(derive("/bɑks/", "plural").ipa, "/bɑksɪz/", "sibilant plural")
equal(derive("[bɑks]", "plural").ipa, "/bɑksɪz/", "bracket stripping")
equal(derive("/weɪt/", "past").ipa, "/weɪtɪd/", "alveolar past")
equal(derive("/wɔk/", "past").ipa, "/wɔkt/", "voiceless past")
truthy(derive("/bɑks/", "plural").simple, "derived readable is missing")
equal(Plugin:derive({{
    ipa = "/mendi/",
    language = "Spanish",
    source = "test",
}}, "plural", "mendi"), nil, "English rules modified a foreign entry")

equal(Plugin:readableFromIpa("/ˈkæt/"), "KAT", "cat readable")
equal(Plugin:readableFromIpa("/ɪˈpɪtəmi/"), "ih-PIT-uh-mee",
    "epitome readable")
equal(Plugin:readableFromIpa("/həˈloʊ/"), "huh-LOH", "hello readable")
equal(Plugin:readableFromIpa("/laminak/"), "lah-mee-nahk",
    "generic IPA readable")
equal(#Plugin:queryLanguageHints("unlisted-word"), 0,
    "missing legacy language-hint table was not handled safely")

-- The bundled, pure-Lua English LTS path handles arbitrary spellings without
-- an installed executable or a dictionary entry.
local fantasy = Plugin:generatePronunciations("zyrathion", {})
truthy(fantasy, "portable English fantasy-word fallback is missing")
equal(#fantasy, 1, "unexpected fantasy-word result count")
equal(fantasy[1].language, "English", "fantasy fallback language")
equal(fantasy[1].region, "US", "fantasy fallback region")
truthy(fantasy[1].ipa and fantasy[1].ipa:match("^/.+/$"),
    "fantasy fallback IPA is malformed")
truthy(fantasy[1].arpabet and fantasy[1].arpabet ~= "",
    "fantasy fallback lost its inferred phones")
equal(fantasy[1].arpabet, "Z AY1 R AE1 TH IY0 AH0 N",
    "portable model diverged from the pinned Flite LTS output")
truthy(fantasy[1].source:find("CMU Flite", 1, true),
    "fantasy fallback provenance is missing")

local accented_fantasy = Plugin:generatePronunciations("Faërun", {})
truthy(accented_fantasy and accented_fantasy[1].ipa,
    "portable English fallback did not fold a Latin-script name")
equal(accented_fantasy[1].arpabet, "F EH1 ER0 AH0 N",
    "Latin folding changed the pinned Flite LTS output")
equal(Plugin:generatePronunciations("“Faërun”", {})[1].arpabet,
    accented_fantasy[1].arpabet,
    "typographic query wrappers were not normalized")

-- Auto mode uses safe, optional book metadata on old and new KOReader builds.
Plugin.queryLanguageHints = function() return {} end
Plugin.generated_language = "auto"
Plugin.ui.document = {
    getProps = function() return { language = "es-ES" } end,
}
local book_hints = Plugin:generationHints("fantasia")
equal(#book_hints, 1, "book language hint is missing")
equal(book_hints[1].code, "es", "BCP-47 book language was not normalized")
local foreign_cache_key = Plugin:generationCacheKey("fantasia", book_hints)
Plugin.ui.document.getProps = function() return { language = "en-US" } end
local english_cache_key = Plugin:generationCacheKey(
    "fantasia", Plugin:generationHints("fantasia"))
truthy(foreign_cache_key ~= english_cache_key,
    "generated cache key ignored the book language")

Plugin.generated_language = "en"
Plugin.ui.document.getProps = function() return { language = "es" } end
equal(Plugin:generationHints("fantasia")[1].code, "en",
    "explicit generated language did not override book metadata")
Plugin.generated_language = "auto"
Plugin.ui.document = nil

Plugin.generated_cache = {}
Plugin.settings = {
    saveSetting = function() end,
    flush = function() end,
}
local menu = {}
Plugin:addToMainMenu(menu)
local language_menu = menu.pronunciation.sub_item_table[3].sub_item_table
equal(#language_menu, 2,
    "generated-language menu should contain only Auto and US English")
language_menu[2].callback()
equal(Plugin.generated_language, "en",
    "generated-language menu did not select US English")
Plugin.generated_language = "auto"

truthy(hasCandidate("running", "run", "ing"), "running -> run missing")
truthy(hasCandidate("stopped", "stop", "past"), "stopped -> stop missing")
truthy(hasCandidate("heroes", "hero", "plural"), "heroes -> hero missing")
truthy(hasCandidate("knives", "knife", "plural"), "knives -> knife missing")
truthy(hasCandidate("lying", "lie", "ing"), "lying -> lie missing")

-- A single offline lookup reuses one database connection for the exact word
-- and all inflection candidates.
local original_open = SQ3.open
local original_query_connection = Plugin._queryConnection
local original_overrides = Plugin.overrides
local original_cache = Plugin.cache
local open_count, close_count = 0, 0
SQ3.open = function()
    open_count = open_count + 1
    return { close = function() close_count = close_count + 1 end }
end
Plugin._queryConnection = function(_, _, word)
    if word == "run" then
        return {{
            ipa = "/ɹʌn/",
            arpabet = "R AH1 N",
            source = "CMUdict",
            confidence = 80,
            region = "US",
        }}
    end
end
Plugin.overrides = {}
Plugin.cache = {}
local offline_derived, offline_match = Plugin:lookupOffline("running")
equal(open_count, 1, "offline candidates reopened the database")
equal(close_count, 1, "offline lookup did not close the database")
equal(offline_match, "run", "offline candidate matched the wrong base")
equal(offline_derived[1].ipa, "/ɹʌnɪŋ/", "offline candidate derivation changed")
SQ3.open = original_open
Plugin._queryConnection = original_query_connection
Plugin.overrides = original_overrides
Plugin.cache = original_cache

local wiktionary_fixture = [[
<div class="mw-heading mw-heading2"><h2 id="English">English</h2></div>
<h3 id="Pronunciation">Pronunciation</h3>
<ul>
<li>(General American) IPA: <span class="IPA">/ɹɪˈzum/</span></li>
<li>(Received Pronunciation) IPA: <span class="IPA">/ɹɪˈzjuːm/</span></li>
</ul>
<div class="mw-heading mw-heading2"><h2 id="Indonesian">Indonesian</h2></div>
<ul><li>IPA: <span class="IPA">/reˈsume/</span></li></ul>
]]
local parsed = Plugin:parseWiktionaryHtml(wiktionary_fixture)
equal(#parsed, 2, "Wiktionary parser leaked a non-English pronunciation")
equal(parsed[1].region, "US", "US label was not retained")
equal(parsed[2].region, "UK", "UK label was not retained")
truthy(parsed[1].simple, "online readable was not generated")
equal(parsed[1].simple_approx, true, "generated readable must be identified")

local dictionary_api = Plugin:parseDictionaryApi({{
    phonetic = "həˈloʊ",
    phonetics = {
        { text = "həˈloʊ", audio = "hello--_us_1.mp3" },
        { text = "hɛˈləʊ", audio = "hello--_gb_1.mp3" },
    },
}})
equal(#dictionary_api, 2, "Dictionary API duplicate was not removed")
equal(dictionary_api[1].region, "US", "Dictionary API US label missing")
equal(dictionary_api[2].region, "UK", "Dictionary API UK label missing")
truthy(dictionary_api[1].simple, "Dictionary API readable missing")

local etymology_fixture = [[
<div class="mw-heading mw-heading2"><h2 id="English">English</h2></div>
<div class="mw-heading mw-heading3"><h3 id="Etymology">Etymology</h3></div>
<p><span class="etyl"><a href="/wiki/Spanish">Spanish</a></span>.</p>
<div class="mw-heading mw-heading3"><h3 id="Noun">Noun</h3></div>
]]
local missing_ipa, language_hints = Plugin:parseWiktionaryHtml(etymology_fixture)
equal(missing_ipa, nil, "etymology-only page invented an exact IPA")
equal(#language_hints, 1, "Spanish etymology hint missing")
equal(language_hints[1].code, "es", "Spanish etymology code")

local formatted = Plugin:format("resume", parsed, "resume")
truthy(formatted:find("IPA (US):", 1, true), "formatted US label missing")
truthy(formatted:find("Readable (approx.):", 1, true),
    "approximate readable label missing")
local generated_formatted = Plugin:format("zyrathion", fantasy, "zyrathion")
truthy(generated_formatted:find("IPA (generated; US English):", 1, true),
    "generated IPA label missing")

-- End-to-end missing-word flow: sourced online lookup is attempted first,
-- then an unsupported language hint safely uses the general English fallback.
Plugin.cache = {}
Plugin.generated_cache = {}
Plugin.settings = {
    saveSetting = function() end,
    flush = function() end,
}
Plugin.lookupOffline = function() return nil end
Plugin.lookupOnline = function()
    return nil, {{ code = "es", name = "Spanish" }}
end
Plugin.queryLanguageHints = function()
    return {{ code = "es", name = "Spanish" }}
end
Plugin.online_fallback = true
Plugin:lookupAndShow("zyrathion")
truthy(shown_widget and shown_widget.text, "missing-word result was not shown")
truthy(shown_widget.text:find("CMU Flite", 1, true),
    "missing-word flow lost generated provenance")
truthy(shown_widget.text:find("generated; US English", 1, true),
    "missing-word flow lost generated provenance")

Plugin.cache = {}
Plugin.generated_cache = {}
Plugin.lookupOnline = function()
    return {{
        ipa = "/sɔːst/",
        source = "Wiktionary",
        confidence = 85,
    }}, {{ code = "es", name = "Spanish" }}
end
Plugin.generatePronunciations = function()
    error("generated fallback ran despite a sourced result")
end
Plugin:lookupAndShow("sourced")
truthy(shown_widget.text:find("Source: Wiktionary", 1, true),
    "sourced result did not win over generation")
truthy(not shown_widget.text:find("generated", 1, true),
    "sourced result was mislabeled as generated")

-- An optional HTML path allows a live MediaWiki response to be checked without
-- making the normal regression suite depend on network access.
if arg[1] then
    local fixture = assert(io.open(arg[1], "r"))
    local live_html = fixture:read("*all")
    fixture:close()
    local live_results = assert(Plugin:parseWiktionaryHtml(live_html))
    local has_us, has_uk = false, false
    for _, result in ipairs(live_results) do
        if result.ipa == "/reˈsume/" then
            error("live parser leaked the Indonesian pronunciation")
        end
        has_us = has_us or result.region == "US"
        has_uk = has_uk or result.region == "UK"
    end
    truthy(has_us, "live parser lost US labels")
    truthy(has_uk, "live parser lost UK labels")
    print("live English Wiktionary pronunciations:", #live_results)
end

print("plugin regression tests: OK")
