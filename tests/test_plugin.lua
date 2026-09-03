local function preload(name, value)
    package.preload[name] = function() return value end
end

local shown_widget
local shown_widgets = {}
local closed_widgets = {}
local repaint_count = 0
local next_tick_count = 0
local keyboard_show_count = 0
local UIManager = {
    show = function(_, widget)
        shown_widget = widget
        shown_widgets[#shown_widgets + 1] = widget
    end,
    close = function(_, widget)
        closed_widgets[#closed_widgets + 1] = widget
    end,
    forceRePaint = function()
        repaint_count = repaint_count + 1
    end,
    nextTick = function(_, callback)
        next_tick_count = next_tick_count + 1
        callback()
    end,
}
local NetworkMgr = {
    runWhenOnline = function(_, callback) callback() end,
}

preload("datastorage", {})
preload("ui/widget/infomessage", { new = function(_, value) return value end })
preload("ui/widget/inputdialog", {
    new = function(_, value)
        value.getInputText = function(self) return self.input end
        value.onShowKeyboard = function()
            keyboard_show_count = keyboard_show_count + 1
        end
        return value
    end,
})
local TextBoxWidget = {
    PTF_HEADER = "<formatted>",
    PTF_BOLD_START = "<bold>",
    PTF_BOLD_END = "</bold>",
}
preload("ui/widget/textboxwidget", TextBoxWidget)
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

-- Heavy feature modules stay out of the startup path on memory-limited devices.
assert(package.loaded["json"] == nil, "JSON was loaded during plugin startup")
assert(package.loaded["lua-ljsqlite3/init"] == nil,
    "SQLite was loaded during plugin startup")
assert(package.loaded["socket.http"] == nil,
    "HTTP was loaded during plugin startup")
assert(package.loaded["ui/widget/dictquicklookup"] == nil,
    "legacy dictionary widget was loaded during modern plugin startup")

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, message)
    if not value then error(message or "expected a truthy value", 2) end
end

local function countValue(rows, expected)
    local count = 0
    for _, row in ipairs(rows or {}) do
        for _, value in ipairs(row) do
            local actual = type(value) == "table" and value.id or value
            if actual == expected then count = count + 1 end
        end
    end
    return count
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
local original_reader_settings = rawget(_G, "G_reader_settings")

-- Missing global settings are valid in stripped-down/custom KOReader builds.
_G.G_reader_settings = nil
local no_settings_dictionary = {
    default_layout = {
        { "prev_dict", "pronunciation_lookup" },
        { "pronunciation_lookup" },
        { "search", "close" },
    },
    addToDictButtons = function(_, spec) modern_spec = spec end,
}
Plugin.ui = { dictionary = no_settings_dictionary }
local no_settings_ok = pcall(function() Plugin:registerDictionaryButton() end)
truthy(no_settings_ok, "modern registration required global reader settings")
equal(countValue(no_settings_dictionary.default_layout,
    "pronunciation_lookup"), 0,
    "stale default-layout buttons survived without reader settings")

-- A clean saved layout must not be rewritten just because the plugin starts.
local clean_config = {
    layout = {{ "prev_dict", "search", "close" }},
    order = { "prev_dict", "search", "close" },
    row_count = { 3 },
}
local clean_save_count = 0
_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "dict_button_config" then return clean_config end
    end,
    saveSetting = function() clean_save_count = clean_save_count + 1 end,
}
Plugin.ui = { dictionary = {
    default_layout = {{ "prev_dict", "search", "close" }},
    addToDictButtons = function(_, spec) modern_spec = spec end,
} }
Plugin:registerDictionaryButton()
equal(clean_save_count, 0, "clean dictionary layout was needlessly rewritten")

-- KOReader's first modern button implementation could persist conditional
-- rows in both default_layout and dict_button_config. Current KOReader then
-- appends the conditional row once more, so migrate every stale occurrence.
local contaminated_config = {
    layout = {
        { "prev_dict", "pronunciation_lookup" },
        { "pronunciation_lookup" },
        { "search", "close" },
        { "pronunciation_lookup" },
    },
    order = {
        "prev_dict", "pronunciation_lookup", "search",
        "pronunciation_lookup", "close",
    },
    row_count = { 2, 1, 2, 1 },
}
local saved_config
_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "dict_button_config" then return contaminated_config end
    end,
    saveSetting = function(_, key, value)
        equal(key, "dict_button_config", "unexpected reader setting changed")
        saved_config = value
    end,
}
local contaminated_dictionary = {
    default_layout = {
        { "prev_dict", "pronunciation_lookup" },
        { "pronunciation_lookup" },
        { "search", "close" },
    },
    addToDictButtons = function(_, spec) modern_spec = spec end,
}
Plugin.ui = { dictionary = contaminated_dictionary }
Plugin:registerDictionaryButton()
equal(countValue(contaminated_dictionary.default_layout,
    "pronunciation_lookup"), 0,
    "contaminated default layout retained the conditional button")
equal(countValue(contaminated_config.layout, "pronunciation_lookup"), 0,
    "saved layout retained the conditional button")
equal(countValue({ contaminated_config.order }, "pronunciation_lookup"), 0,
    "saved button order retained the conditional button")
equal(#contaminated_config.layout, 2,
    "empty contaminated layout rows were not removed")
equal(#contaminated_config.row_count, 2,
    "row counts were not kept aligned with the migrated layout")
equal(contaminated_config.row_count[1], 2,
    "first surviving row count changed during migration")
equal(contaminated_config.row_count[2], 2,
    "second surviving row count changed during migration")
equal(saved_config, contaminated_config,
    "migrated dictionary layout was not saved")

-- The same repair runs while each popup is assembled, so it also handles a
-- layout contaminated after registration (for example, by an old core build).
table.insert(contaminated_config.layout, { "pronunciation_lookup" })
table.insert(contaminated_config.order, "pronunciation_lookup")
table.insert(contaminated_config.row_count, 1)
saved_config = nil
truthy(modern_spec.show_func({
    ui = { dictionary = contaminated_dictionary },
    is_wiki_fullpage = false,
}), "modern button was hidden while migrating a saved layout")
equal(countValue(contaminated_config.layout, "pronunciation_lookup"), 0,
    "per-popup migration retained a saved conditional button")
equal(saved_config, contaminated_config,
    "per-popup saved-layout migration was not persisted")

-- v2026.07 builds the saved rows, then appends each conditional row. After
-- migration that assembly must contain exactly one pronunciation button.
local modern_rendered_count = countValue(contaminated_config.layout,
    "pronunciation_lookup")
if modern_spec and modern_spec.conditional then
    modern_rendered_count = modern_rendered_count + 1
end
equal(modern_rendered_count, 1,
    "modern dictionary layout still renders duplicate pronunciation buttons")

-- KOReader ed695fe3 before 17b9a64 appended the transient row directly to
-- default_layout. The per-popup show hook must repair that mutation before
-- every build, not only once when the plugin registers.
local buggy_dictionary = {
    default_layout = {{ "prev_dict", "search", "close" }},
    addToDictButtons = function(_, spec) modern_spec = spec end,
}
local missing_config_save_count = 0
_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() missing_config_save_count =
        missing_config_save_count + 1 end,
}
Plugin.ui = { dictionary = buggy_dictionary }
Plugin:registerDictionaryButton()
local buggy_popup = {
    ui = { dictionary = buggy_dictionary },
    is_wiki_fullpage = false,
}
local function simulateBuggyModernPopupBuild()
    truthy(modern_spec.show_func(buggy_popup),
        "modern button was hidden in a dictionary popup")
    -- This intentionally reproduces KOReader's old aliasing bug: its runtime
    -- layout and default_layout were the same table when no config existed.
    table.insert(buggy_dictionary.default_layout, { modern_spec.id })
    return countValue(buggy_dictionary.default_layout, modern_spec.id)
end
equal(simulateBuggyModernPopupBuild(), 1,
    "first buggy-core popup rendered an unexpected button count")
equal(simulateBuggyModernPopupBuild(), 1,
    "second buggy-core popup duplicated the pronunciation button")
equal(missing_config_save_count, 0,
    "missing dictionary config triggered a settings write")
equal(modern_spec.show_func({
    ui = { dictionary = buggy_dictionary },
    is_wiki_fullpage = true,
}), false, "modern button appeared in full-page Wikipedia")
_G.G_reader_settings = original_reader_settings

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

-- The bundled, pure-Lua weighted G2P path handles arbitrary spellings without
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
equal(fantasy[1].arpabet, "Z ER0 AE1 TH IY0 AO0 N",
    "portable model diverged from the pinned MFA/Pynini output")
truthy(fantasy[1].source:find("MFA/Pynini", 1, true),
    "fantasy fallback provenance is missing")
local laminak = Plugin:generatePronunciations("laminak", {})
truthy(laminak and laminak[1], "laminak G2P regression is missing")
equal(laminak[1].arpabet, "L AE1 M AH0 N AH0 K",
    "laminak diverged from the pinned MFA/Pynini output")

local accented_fantasy = Plugin:generatePronunciations("Faërun", {})
truthy(accented_fantasy and accented_fantasy[1].ipa,
    "portable English fallback did not fold a Latin-script name")
equal(accented_fantasy[1].arpabet, "F EH1 R AH0 N",
    "Latin folding changed the pinned MFA/Pynini output")
equal(Plugin:generatePronunciations("FAËRUN", {})[1].arpabet,
    accented_fantasy[1].arpabet,
    "uppercase accented Latin spelling was not normalized")
equal(Plugin:generatePronunciations("“Faërun”", {})[1].arpabet,
    accented_fantasy[1].arpabet,
    "typographic query wrappers were not normalized")

-- Auto mode uses safe, optional book metadata on old and new KOReader builds.
local query_language_hints_method = Plugin.queryLanguageHints
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
equal(foreign_cache_key, english_cache_key,
    "unsupported language fragmented the English generator cache")

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

-- Both public generated-fallback paths must go through the generated cache.
-- Normalized spelling variants share an entry and never decode the model twice.
local cached_g2p_method = Plugin._englishG2pPhones
local cached_lookup_offline = Plugin.lookupOffline
local cached_online_fallback = Plugin.online_fallback
local cached_g2p_calls = 0
Plugin._englishG2pPhones = function(plugin, word)
    cached_g2p_calls = cached_g2p_calls + 1
    return cached_g2p_method(plugin, word)
end
Plugin.lookupOffline = function() return nil end
Plugin.online_fallback = false
Plugin.generated_cache = {}
Plugin:_lookupAndShow("Zyrathion")
Plugin.lookupOffline = function()
    error("cached generated result reached the offline database lookup")
end
Plugin:_lookupAndShow("“ZYRATHION”")
equal(cached_g2p_calls, 1,
    "offline generated fallback did not reuse its cached result")
local normalized_generated_key = Plugin:generationCacheKey(
    "zyrathion", Plugin:generationHints("zyrathion"))
truthy(Plugin.generated_cache[normalized_generated_key],
    "offline generated fallback did not save its result")
Plugin._englishG2pPhones = cached_g2p_method
Plugin.lookupOffline = cached_lookup_offline
Plugin.online_fallback = cached_online_fallback

local menu = {}
Plugin:addToMainMenu(menu)
equal(menu.pronunciation_lookup.sorting_hint, "search",
    "manual pronunciation lookup was not assigned to the Search menu")
equal(menu.pronunciation_lookup.text, "Pronunciation lookup",
    "manual pronunciation lookup menu label")
equal(menu.pronunciation.sorting_hint, "search_settings",
    "pronunciation settings were not assigned beside Dictionary settings")
local language_menu = menu.pronunciation.sub_item_table[3].sub_item_table
equal(#language_menu, 2,
    "generated-language menu should contain only Auto and US English")
language_menu[2].callback()
equal(Plugin.generated_language, "en",
    "generated-language menu did not select US English")
Plugin.generated_language = "auto"

-- Manual pronunciation lookup mirrors KOReader's dictionary lookup dialog.
local menu_lookup_word
local menu_lookup = Plugin.lookupAndShow
Plugin.lookupAndShow = function(_, word) menu_lookup_word = word end
shown_widgets = {}
closed_widgets = {}
keyboard_show_count = 0
menu.pronunciation_lookup.callback()
local lookup_dialog = shown_widgets[#shown_widgets]
truthy(lookup_dialog, "manual pronunciation lookup dialog was not shown")
equal(lookup_dialog.title, "Enter a word or phrase to look up",
    "manual pronunciation lookup dialog title")
equal(lookup_dialog.input_type, "text",
    "manual pronunciation lookup input type")
equal(keyboard_show_count, 1,
    "manual pronunciation lookup did not show the keyboard")
equal(lookup_dialog.buttons[1][2].is_enter_default, true,
    "manual pronunciation lookup is not the enter-key default")
lookup_dialog.input = "   "
lookup_dialog.buttons[1][2].callback()
equal(menu_lookup_word, nil, "blank manual pronunciation lookup was submitted")
equal(#closed_widgets, 0, "blank manual pronunciation lookup closed its dialog")
lookup_dialog.input = "Faërun"
lookup_dialog.buttons[1][2].callback()
equal(menu_lookup_word, "Faërun", "manual pronunciation lookup changed its query")
equal(closed_widgets[1], lookup_dialog,
    "manual pronunciation lookup did not close before searching")

menu.pronunciation_lookup.callback()
local cancelled_lookup_dialog = shown_widgets[#shown_widgets]
cancelled_lookup_dialog.buttons[1][1].callback()
equal(closed_widgets[#closed_widgets], cancelled_lookup_dialog,
    "manual pronunciation lookup cancel did not close its dialog")
Plugin.lookupAndShow = menu_lookup

-- Generated entries are reproducible offline, so stale formats and excessive
-- history must not grow the startup settings table without bound.
Plugin.generated_cache = { ["generator:2|old"] = {{ ipa = "/oʊld/" }} }
for index = 1, 140 do
    Plugin.generated_cache["generator:3|test:" .. index] = {{ ipa = "/tɛst/" }}
end
Plugin:saveGeneratedCache("generator:3|test:current", {{ ipa = "/kɝənt/" }})
local generated_cache_count = 0
for key in pairs(Plugin.generated_cache) do
    generated_cache_count = generated_cache_count + 1
    truthy(key:find("generator:3|", 1, true) == 1,
        "stale generator cache version survived pruning")
end
truthy(generated_cache_count <= 128, "generated cache limit was not enforced")
truthy(Plugin.generated_cache["generator:3|test:current"],
    "new generated cache entry was pruned")

-- Online results are recoverable, so their settings cache is bounded and
-- unused descriptions are stripped before serialization.
Plugin.cache = {}
for index = 1, 270 do
    Plugin.cache["cached-" .. index] = {{
        ipa = "/tɛst/",
        note = "unused description",
    }}
end
Plugin:saveCache("cached-current", {{
    ipa = "/kɝənt/",
    note = "unused description",
}})
local sourced_cache_count = 0
for _, results in pairs(Plugin.cache) do
    sourced_cache_count = sourced_cache_count + 1
    equal(results[1].note, nil, "sourced cache retained an unused description")
end
truthy(sourced_cache_count <= 256, "sourced cache limit was not enforced")
truthy(Plugin.cache["cached-current"], "new sourced cache entry was pruned")
local cached_overrides = Plugin.overrides
local cached_database_open = SQ3.open
local cached_database_open_count = 0
Plugin.overrides = {}
SQ3.open = function()
    cached_database_open_count = cached_database_open_count + 1
    error("sourced cache lookup opened the database")
end
local cached_sourced, cached_sourced_match =
    Plugin:lookupOffline("“CACHED-CURRENT”")
truthy(cached_sourced and cached_sourced[1],
    "offline lookup did not reuse the normalized sourced cache entry")
equal(cached_sourced_match, "cached-current",
    "sourced cache returned the wrong normalized match")
equal(cached_database_open_count, 0,
    "sourced cache was checked after opening the database")
Plugin.overrides = cached_overrides
SQ3.open = cached_database_open

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
local database_mode
SQ3.open = function(_, mode)
    database_mode = mode
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
equal(database_mode, "ro", "bundled database was not opened read-only")
equal(offline_match, "run", "offline candidate matched the wrong base")
equal(offline_derived[1].ipa, "/ɹʌnɪŋ/", "offline candidate derivation changed")
SQ3.open = original_open
Plugin._queryConnection = original_query_connection
Plugin.overrides = original_overrides
Plugin.cache = original_cache

-- The real query path prepares once and resets the same statement for each
-- inflection candidate checked on a connection.
local prepare_count, reset_count, statement_close_count = 0, 0, 0
local active_word
local fake_statement = {
    reset = function(self)
        reset_count = reset_count + 1
        return self
    end,
    bind = function(self, ...)
        equal(select("#", ...), 1,
            "pronunciation query received an extra bound value")
        local word = ...
        active_word = word
        self.returned = false
    end,
    step = function(self)
        if active_word == "cat" and not self.returned then
            self.returned = true
            return { "/ˈkæt/", "K AE1 T", "KAT", "CMUdict", 80,
                "US", 0 }
        end
    end,
    close = function() statement_close_count = statement_close_count + 1 end,
}
local fake_connection = {
    prepare = function()
        prepare_count = prepare_count + 1
        return fake_statement
    end,
}
local missing, missing_error, reusable = Plugin:_queryConnection(
    fake_connection, "missing")
equal(missing, nil, "missing reusable query returned a row")
equal(missing_error, nil, "missing reusable query returned an error")
local found, found_error, reused = Plugin:_queryConnection(
    fake_connection, "cat", reusable)
truthy(found and found[1], "reused query lost a pronunciation")
equal(found_error, nil, "reused query returned an error")
equal(reused, reusable, "query did not return the reusable statement")
equal(found[1].region, "US", "compact query shifted the region column")
equal(found[1].simple_approx, false,
    "compact query shifted the readable-approximation column")
equal(prepare_count, 1, "candidate queries prepared more than once")
equal(reset_count, 1, "reused candidate statement was not reset")
reused:close()
equal(statement_close_count, 1, "reused statement did not close")

-- Normalization helpers must return exactly one value when passed directly to
-- prepared-query methods; string.gsub otherwise leaks its replacement count.
local query_connection_close_count = 0
fake_connection.close = function()
    query_connection_close_count = query_connection_close_count + 1
end
local query_open = SQ3.open
local query_mode
SQ3.open = function(_, mode)
    query_mode = mode
    return fake_connection
end
local queried = Plugin:query("“CAT”")
truthy(queried and queried[1], "normalized direct query lost its result")
equal(queried[1].ipa, "/ˈkæt/", "normalized direct query returned wrong IPA")
equal(query_mode, "ro", "direct query did not open the database read-only")
equal(prepare_count, 2, "direct query did not prepare exactly one statement")
equal(statement_close_count, 2, "direct query did not close its statement")
equal(query_connection_close_count, 1,
    "direct query did not close its database connection")

local hint_bind_count = 0
local hint_word
local hint_returned = false
local hint_statement = {
    bind = function(_, ...)
        hint_bind_count = select("#", ...)
        hint_word = ...
    end,
    step = function()
        if hint_returned then return nil end
        hint_returned = true
        return { "es", "Spanish", "test language hint" }
    end,
    close = function() end,
}
SQ3.open = function()
    return {
        prepare = function() return hint_statement end,
        close = function() end,
    }
end
local normalized_hints = query_language_hints_method(Plugin, "“FANTASIA”")
equal(hint_bind_count, 1,
    "language-hint query received an extra bound value")
equal(hint_word, "fantasia", "language-hint query did not normalize its word")
equal(normalized_hints[1].code, "es", "language-hint query lost its result")
SQ3.open = query_open

local wiktionary_fixture = [[
<div class="mw-heading mw-heading2"><h2 id="English">English</h2></div>
<h3 id="Pronunciation">Pronunciation</h3>
<ul>
<li>(General American) IPA: <span class="IPA">/ɹɪˈzum/</span></li>
<li>(Received Pronunciation) IPA: <span class="IPA">/ɹɪˈzjuːm/</span></li>
<li>Rhymes: <span class="IPA">-uːm</span></li>
<li>Suffix: <span class="IPA">/-ʃʊ-/</span></li>
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
local normalized_api = Plugin:parseDictionaryApi({{ phonetic = "/tɛst" }})
equal(normalized_api[1].ipa, "/tɛst/",
    "online IPA with one wrapper was not normalized")

local dict_api_method = Plugin.dictApi
local wiktionary_method = Plugin.wiktionary
Plugin.dictApi = function()
    return {{ ipa = "/dɪkt/", source = "Dictionary", confidence = 75 }}
end
Plugin.wiktionary = function()
    return {{ ipa = "/wɪki/", source = "Wiktionary", confidence = 85 }}
end
local ordered_online = Plugin:lookupOnline("test")
equal(ordered_online[1].source, "Wiktionary",
    "online results were not ordered by confidence")
Plugin.dictApi = dict_api_method
Plugin.wiktionary = wiktionary_method

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
truthy(formatted:find("<formatted><bold>resume</bold>", 1, true) == 1,
    "queried word was not bolded")
truthy(formatted:find("IPA (US):", 1, true), "formatted US label missing")
truthy(formatted:find("Readable (approx.):", 1, true),
    "approximate readable label missing")
truthy(formatted:find("Source: Wiktionary", 1, true),
    "compact formatting lost source attribution")
truthy(not formatted:find("Confidence:", 1, true),
    "confidence score was not removed from the UI")
truthy(not formatted:find("learned online and cached locally", 1, true),
    "source description was not removed")
local ptf_header = TextBoxWidget.PTF_HEADER
TextBoxWidget.PTF_HEADER = nil
local legacy_formatted = Plugin:format("resume", parsed, "resume")
equal(legacy_formatted:sub(1, #"resume"), "resume",
    "old KOReader heading fallback changed the query")
TextBoxWidget.PTF_HEADER = ptf_header
local generated_formatted = Plugin:format("zyrathion", fantasy, "zyrathion")
truthy(generated_formatted:find("IPA (generated; US English):", 1, true),
    "generated IPA label missing")

local original_overrides = Plugin.overrides
Plugin.overrides = { cat = { ipa = "[kæt]", simple = "KAT" } }
equal(Plugin:getOverride("cat")[1].ipa, "/kæt/",
    "stored override IPA was not normalized")
Plugin.overrides = original_overrides

-- Older KOReader builds without the repaint scheduling helpers still perform
-- an exact offline lookup and close the progress popup synchronously.
local lookup_offline = Plugin.lookupOffline
local next_tick = UIManager.nextTick
local force_repaint = UIManager.forceRePaint
Plugin.lookupOffline = function()
    return {{
        ipa = "/ˈkæt/",
        source = "CMUdict",
        confidence = 95,
    }}, "cat"
end
UIManager.nextTick = nil
UIManager.forceRePaint = nil
shown_widgets = {}
closed_widgets = {}
Plugin:lookupAndShow("cat")
equal(#shown_widgets, 2, "legacy offline lookup did not show progress and result")
equal(shown_widgets[1].text, "Looking up pronunciation…",
    "legacy offline progress text changed")
equal(closed_widgets[1], shown_widgets[1],
    "legacy offline progress was not closed")
truthy(shown_widget.text:find("Source: CMUdict", 1, true),
    "legacy offline result was not shown")
Plugin.lookupOffline = lookup_offline
UIManager.nextTick = next_tick
UIManager.forceRePaint = force_repaint

-- End-to-end missing-word flow: sourced online lookup is attempted first,
-- then an unsupported language hint safely uses the general English fallback.
Plugin.cache = {}
Plugin.generated_cache = {}
Plugin.settings = {
    saveSetting = function() end,
    flush = function() end,
}
Plugin.lookupOffline = function() return nil end
local online_lookup_calls = 0
Plugin.lookupOnline = function()
    online_lookup_calls = online_lookup_calls + 1
    return nil, {{ code = "es", name = "Spanish" }}
end
Plugin.queryLanguageHints = function()
    return {{ code = "es", name = "Spanish" }}
end
Plugin.online_fallback = true
local online_g2p_method = Plugin._englishG2pPhones
local online_g2p_calls = 0
Plugin._englishG2pPhones = function(plugin, word)
    online_g2p_calls = online_g2p_calls + 1
    return online_g2p_method(plugin, word)
end
shown_widget = nil
shown_widgets = {}
closed_widgets = {}
repaint_count = 0
next_tick_count = 0
Plugin:lookupAndShow("zyrathion")
equal(#shown_widgets, 2, "online lookup did not reuse its painted progress popup")
equal(shown_widgets[1].text, "Looking up pronunciation…",
    "lookup progress text changed")
equal(shown_widgets[1].dismissable, false,
    "lookup progress can be dismissed while work is running")
equal(repaint_count, 1, "lookup progress was not painted before blocking work")
equal(next_tick_count, 2, "lookup work did not yield to the UI event loop")
equal(online_lookup_calls, 1, "missing-word flow repeated its online lookup")
equal(closed_widgets[1], shown_widgets[1], "offline progress was not closed")
truthy(shown_widget and shown_widget.text, "missing-word result was not shown")
truthy(shown_widget.text:find("MFA/Pynini", 1, true),
    "missing-word flow lost generated provenance")
truthy(shown_widget.text:find("generated; US English", 1, true),
    "missing-word flow lost generated provenance")
local shown_before_cached_lookup = #shown_widgets
local repaint_before_cached_lookup = repaint_count
local ticks_before_cached_lookup = next_tick_count
Plugin:lookupAndShow("“ZYRATHION”")
equal(online_g2p_calls, 1,
    "online missing-word flow regenerated an existing cached pronunciation")
equal(online_lookup_calls, 1,
    "cached generated result repeated the online source lookup")
equal(#shown_widgets, shown_before_cached_lookup + 1,
    "cached generated result showed a progress popup")
equal(repaint_count, repaint_before_cached_lookup,
    "cached generated result triggered an extra repaint")
equal(next_tick_count, ticks_before_cached_lookup,
    "cached generated result deferred work to the event loop")
Plugin._englishG2pPhones = online_g2p_method

-- A canceled Wi-Fi prompt never runs its callback, so the first progress
-- message must be closed before control passes to KOReader's network manager.
local run_when_online = NetworkMgr.runWhenOnline
NetworkMgr.runWhenOnline = function() end
shown_widgets = {}
closed_widgets = {}
Plugin:lookupAndShow("cancelled")
equal(#shown_widgets, 1, "network handoff showed an unexpected popup")
equal(#closed_widgets, 1, "network handoff stranded its progress popup")
equal(closed_widgets[1], shown_widgets[1],
    "network handoff did not close the initial progress popup")

-- If KOReader connects asynchronously, the plugin paints a new progress popup
-- immediately before the deferred HTTP lookup.
local pending_online_callback
NetworkMgr.runWhenOnline = function(_, callback)
    pending_online_callback = callback
end
shown_widgets = {}
closed_widgets = {}
repaint_count = 0
next_tick_count = 0
Plugin:lookupAndShow("delayed")
equal(#shown_widgets, 1, "deferred lookup showed an early online popup")
equal(#closed_widgets, 1, "deferred lookup stranded its initial popup")
truthy(pending_online_callback, "deferred lookup callback was not retained")
pending_online_callback()
equal(#shown_widgets, 3, "deferred online progress or result was not shown")
equal(shown_widgets[2].text, "Looking up pronunciation…",
    "deferred online progress text changed")
equal(closed_widgets[2], shown_widgets[2],
    "deferred online progress was not closed")
equal(repaint_count, 2, "deferred online progress was not painted")
NetworkMgr.runWhenOnline = run_when_online

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
