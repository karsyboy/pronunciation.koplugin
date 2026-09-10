local logger = require("logger")

local M = {}

M.MAX_OUTPUT_TOKENS = 128
M.MAX_HTTP_RESPONSE_BYTES = 65536
M.MAX_MODEL_LIST_BYTES = 262144
M.MAX_MODELS = 1000
M.MAX_MODEL_TEXT_BYTES = 2048

M.PROMPT = [[Pronounce the input word.
Output exactly two lines:
IPA: /{IPA}/
Pronunciation: {English-readable pronunciation; CAPS = stressed syllable}
Use the standard native pronunciation. Infer the language unless provided.
Never output anything else. No blank lines, explanations, alternatives, tips, examples, audio/practice suggestions, markdown, or follow-ups.]]

M.providers = {
    {
        id = "gemini", name = "Google Gemini",
        endpoint = "https://generativelanguage.googleapis.com/v1beta/models/",
        model = "gemini-3.7-flash", format = "gemini",
    },
    {
        id = "openai", name = "OpenAI",
        endpoint = "https://api.openai.com/v1/chat/completions",
        model = "gpt-5.4-mini", format = "openai",
    },
    {
        id = "deepseek", name = "DeepSeek",
        endpoint = "https://api.deepseek.com/chat/completions",
        model = "deepseek-chat", format = "openai",
    },
    {
        id = "claude", name = "Anthropic Claude",
        endpoint = "https://api.anthropic.com/v1/messages",
        model = "claude-haiku-4-5-20251001", format = "anthropic",
    },
    { id = "custom1", name = "Custom API 1", format = "openai" },
    { id = "custom2", name = "Custom API 2", format = "openai" },
}

local providers_by_id = {}
for _, provider in ipairs(M.providers) do
    providers_by_id[provider.id] = provider
end

local function trim(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function jsonModule()
    local ok, json = pcall(require, "json")
    if not ok then ok, json = pcall(require, "rapidjson") end
    return ok and json or nil
end

local function jsonDecode(json, value)
    local simple = type(json.decode) == "table" and json.decode.simple or nil
    local ok, decoded
    if simple then
        ok, decoded = pcall(json.decode, value, simple)
    else
        ok, decoded = pcall(json.decode, value)
    end
    if ok then return decoded end
end

function M.provider(id)
    return providers_by_id[id]
end

function M.defaultConfig()
    local configs = {}
    for _, provider in ipairs(M.providers) do
        configs[provider.id] = {
            api_key = "",
            endpoint = provider.endpoint or "",
            model = provider.model or "",
            format = provider.format,
        }
    end
    return configs
end

function M.normalizeConfigs(configs)
    local defaults = M.defaultConfig()
    if type(configs) ~= "table" then return defaults end
    for id, default in pairs(defaults) do
        local saved = configs[id]
        if type(saved) == "table" then
            for _, field in ipairs({ "api_key", "endpoint", "model", "format" }) do
                if type(saved[field]) == "string" then
                    default[field] = trim(saved[field])
                end
            end
        end
        if id ~= "custom1" and id ~= "custom2" then
            default.endpoint = providers_by_id[id].endpoint
            default.format = providers_by_id[id].format
        elseif default.format ~= "anthropic" then
            default.format = "openai"
        end
    end
    return defaults
end

function M.usableConfig(id, config)
    local provider = providers_by_id[id]
    if not provider or type(config) ~= "table" then return false end
    if trim(config.api_key) == "" or trim(config.model) == "" then return false end
    if id == "custom1" or id == "custom2" then
        local endpoint = trim(config.endpoint)
        if endpoint == "" or not endpoint:match("^https?://") then return false end
        if config.format ~= "openai" and config.format ~= "anthropic" then
            return false
        end
    end
    return true
end

function M.inputText(word, language)
    local function oneLine(value)
        value = trim(value):gsub("[%c]", " "):gsub("%s+", " ")
        return trim(value)
    end
    local input = "Word: " .. oneLine(word)
    language = oneLine(language)
    if language ~= "" then input = input .. "\nLanguage: " .. language end
    return input
end

local function safeModel(model)
    model = trim(model)
    if model == "" or #model > 200
            or model:find("[^%w%._%-%/:]", 1) then return nil end
    return model
end

local function safeEndpoint(endpoint)
    endpoint = trim(endpoint)
    if #endpoint > 2048 or not endpoint:match("^https?://") then return nil end
    return endpoint
end

local function customModelsEndpoint(endpoint)
    endpoint = safeEndpoint(endpoint)
    if not endpoint then return nil end
    endpoint = endpoint:gsub("[?#].*$", ""):gsub("/+$", "")
    if endpoint:sub(-7) == "/models" then return endpoint end
    local replaced
    for _, suffix in ipairs({ "/chat/completions", "/responses", "/messages" }) do
        if endpoint:sub(-#suffix) == suffix then
            endpoint = endpoint:sub(1, -#suffix - 1) .. "/models"
            replaced = true
            break
        end
    end
    if not replaced then endpoint = endpoint .. "/models" end
    return endpoint
end

function M.buildModelsRequest(id, config)
    local provider = providers_by_id[id]
    if not provider or type(config) ~= "table"
            or trim(config.api_key) == "" then return nil end

    local endpoint
    if id == "gemini" then
        endpoint = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
    elseif id == "openai" then
        endpoint = "https://api.openai.com/v1/models"
    elseif id == "deepseek" then
        endpoint = "https://api.deepseek.com/models"
    elseif id == "claude" then
        endpoint = "https://api.anthropic.com/v1/models?limit=1000"
    else
        endpoint = customModelsEndpoint(config.endpoint)
    end
    if not endpoint then return nil end

    local headers = {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
    }
    local format = provider.format
    if id == "custom1" or id == "custom2" then
        format = config.format
        if format ~= "openai" and format ~= "anthropic" then return nil end
    end
    if id == "gemini" then
        headers["x-goog-api-key"] = config.api_key
    elseif id == "claude" then
        headers["anthropic-version"] = "2023-06-01"
        headers["x-api-key"] = config.api_key
    elseif format == "anthropic"
            and endpoint:find("api.anthropic.com", 1, true) then
        headers["anthropic-version"] = "2023-06-01"
        headers["x-api-key"] = config.api_key
    else
        headers["Authorization"] = "Bearer " .. config.api_key
    end
    return {
        url = endpoint,
        method = "GET",
        headers = headers,
        provider = id,
        provider_name = provider.name,
        max_response_bytes = M.MAX_MODEL_LIST_BYTES,
    }
end

function M.buildRequest(id, config, word, language)
    local provider = providers_by_id[id]
    local json = jsonModule()
    if not provider or not json or not M.usableConfig(id, config) then return nil end
    local model = safeModel(config.model)
    if not model then return nil end

    local format = provider.format
    local endpoint = provider.endpoint
    if id == "custom1" or id == "custom2" then
        format = config.format
        endpoint = safeEndpoint(config.endpoint)
    end
    if not endpoint then return nil end

    local headers = {
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["Content-Type"] = "application/json",
    }
    local body
    local input = M.inputText(word, language)
    if format == "gemini" then
        endpoint = endpoint .. model .. ":generateContent"
        headers["x-goog-api-key"] = config.api_key
        body = json.encode({
            system_instruction = { parts = {{ text = M.PROMPT }} },
            contents = {{ role = "user", parts = {{ text = input }} }},
            generationConfig = {
                temperature = 0,
                maxOutputTokens = M.MAX_OUTPUT_TOKENS,
            },
        })
    elseif format == "anthropic" then
        headers["anthropic-version"] = "2023-06-01"
        if id == "claude" or endpoint:find("api.anthropic.com", 1, true) then
            headers["x-api-key"] = config.api_key
        else
            headers["Authorization"] = "Bearer " .. config.api_key
        end
        body = json.encode({
            model = model,
            max_tokens = M.MAX_OUTPUT_TOKENS,
            temperature = 0,
            system = M.PROMPT,
            messages = {{ role = "user", content = input }},
        })
    else
        headers["Authorization"] = "Bearer " .. config.api_key
        if (id == "custom1" or id == "custom2")
                and endpoint:find("openrouter.ai", 1, true) then
            headers["HTTP-Referer"] =
                "https://github.com/karsyboy/pronunciation.koplugin"
            headers["X-Title"] = "KOReader Pronunciation"
        end
        local payload = {
            model = model,
            messages = {
                { role = "system", content = M.PROMPT },
                { role = "user", content = input },
            },
        }
        if model:find("^gpt%-5") or model:find("^o[13]") then
            payload.max_completion_tokens = M.MAX_OUTPUT_TOKENS
            payload.reasoning_effort = "low"
        elseif model:find("^gpt%-4o") then
            payload.max_completion_tokens = M.MAX_OUTPUT_TOKENS
            payload.temperature = 0
        else
            payload.max_tokens = M.MAX_OUTPUT_TOKENS
            payload.temperature = 0
        end
        body = json.encode(payload)
    end
    headers["Content-Length"] = tostring(#body)
    return {
        url = endpoint,
        headers = headers,
        body = body,
        provider = id,
        provider_name = provider.name,
        model = model,
        format = format,
    }
end

local function performHttpRequest(request)
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_socketutil, socketutil = pcall(require, "socketutil")
    -- KOReader's LuaSocket HTTPS support is initialized by loading ssl.https.
    pcall(require, "ssl.https")
    if not ok_http or not ok_ltn12 or not ok_socketutil then
        return nil, "unavailable"
    end
    local response = {}
    local max_response_bytes = tonumber(request.max_response_bytes)
        or M.MAX_HTTP_RESPONSE_BYTES
    if max_response_bytes < 1 or max_response_bytes > M.MAX_MODEL_LIST_BYTES then
        max_response_bytes = M.MAX_HTTP_RESPONSE_BYTES
    end
    local response_size = 0
    local oversized = false
    local function boundedSink(chunk)
        if chunk then
            response_size = response_size + #chunk
            if response_size > max_response_bytes then
                oversized = true
                return nil, "response too large"
            end
            response[#response + 1] = chunk
        end
        return 1
    end
    socketutil:set_timeout(15, 25)
    local pcall_ok, ok, code, headers, status = pcall(function()
        local options = {
            url = request.url,
            method = request.method or "POST",
            headers = request.headers,
            sink = boundedSink,
        }
        if type(request.body) == "string" then
            options.source = ltn12.source.string(request.body)
        end
        return http.request(options)
    end)
    socketutil:reset_timeout()
    if not pcall_ok or oversized then return nil, "failed" end
    local text = table.concat(response)
    if #text > max_response_bytes then return nil, "oversized" end
    local expected = headers and tonumber(headers["content-length"]
        or headers["Content-Length"])
    if expected and #text < expected then return nil, "incomplete" end
    return ok, code, text, status
end

function M.extractModels(id, response)
    if type(response) ~= "string" or #response == 0
            or #response > M.MAX_MODEL_LIST_BYTES then return nil end
    local json = jsonModule()
    if not json then return nil end
    local decoded = jsonDecode(json, response)
    if type(decoded) ~= "table" then return nil end

    local rows = id == "gemini" and decoded.models or decoded.data
    if type(rows) ~= "table" then return nil end
    local models, seen = {}, {}
    for _, row in ipairs(rows) do
        local allowed = true
        if id == "gemini" then
            allowed = false
            for _, method in ipairs(type(row) == "table"
                    and row.supportedGenerationMethods or {}) do
                if method == "generateContent" then
                    allowed = true
                    break
                end
            end
        end
        local model = type(row) == "table" and (row.id or row.name) or nil
        if id == "gemini" and type(model) == "string" then
            model = model:gsub("^models/", "")
        end
        model = safeModel(model)
        if allowed and model and not seen[model] then
            seen[model] = true
            models[#models + 1] = model
            if #models >= M.MAX_MODELS then break end
        end
    end
    table.sort(models, function(left, right)
        return left:lower() < right:lower()
    end)
    return #models > 0 and models or nil
end

function M.listModels(id, config, progress, request_function)
    local request = M.buildModelsRequest(id, config)
    if not request then return nil, "configure API key and endpoint" end
    local response, request_error = (request_function or M.request)(request, progress)
    if not response then return nil, request_error or "request failed" end
    local models = M.extractModels(id, response)
    if not models then return nil, "invalid response" end
    return models
end

function M.request(request, progress)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if not ok_trapper or not Trapper
            or type(Trapper.dismissableRunInSubprocess) ~= "function" then
        logger.warn("Pronunciation AI: subprocess networking unavailable for",
            request.provider_name)
        return nil, "request failed"
    end
    local completed, ok, code, response =
        Trapper:dismissableRunInSubprocess(function()
            return performHttpRequest(request)
        end, progress)
    if not completed then return nil, "cancelled" end
    if not ok or tonumber(code) ~= 200 or type(response) ~= "string" then
        logger.warn("Pronunciation AI: request failed for",
            request.provider_name, "HTTP", tostring(tonumber(code) or "network"))
        return nil, "request failed"
    end
    return response
end

function M.extractText(format, response)
    if type(response) ~= "string" or #response > M.MAX_HTTP_RESPONSE_BYTES then
        return nil
    end
    local json = jsonModule()
    if not json then return nil end
    local decoded = jsonDecode(json, response)
    if type(decoded) ~= "table" then return nil end
    if format == "gemini" then
        local candidate = type(decoded.candidates) == "table"
            and decoded.candidates[1] or nil
        local parts = candidate and candidate.content and candidate.content.parts
        if type(parts) ~= "table" then return nil end
        local text = {}
        for _, part in ipairs(parts) do
            if type(part) == "table" and type(part.text) == "string"
                    and not part.thought then text[#text + 1] = part.text end
        end
        return table.concat(text)
    elseif format == "anthropic" then
        local text = {}
        for _, part in ipairs(type(decoded.content) == "table"
                and decoded.content or {}) do
            if type(part) == "table" and part.type == "text"
                    and type(part.text) == "string" then
                text[#text + 1] = part.text
            end
        end
        return table.concat(text)
    end
    local choice = type(decoded.choices) == "table" and decoded.choices[1]
    local message = type(choice) == "table" and choice.message
    return type(message) == "table" and type(message.content) == "string"
        and message.content or nil
end

function M.parseOutput(text)
    if type(text) ~= "string" or #text == 0
            or #text > M.MAX_MODEL_TEXT_BYTES then return nil end
    text = trim(text:gsub("\r\n", "\n"):gsub("\r", "\n"))
    local fenced = text:match("^```[^\n]*\n(.-)\n```$")
    if fenced then text = trim(fenced) end
    local first, second = text:match("^([^\n]+)\n([^\n]+)$")
    if not first or not second then return nil end
    local ipa = first:match("^%s*IPA:%s*(/.-/)%s*$")
    local readable = second:match("^%s*Pronunciation:%s*(.-)%s*$")
    if not ipa or not readable then return nil end
    local core = ipa:sub(2, -2)
    if trim(core) == "" or trim(readable) == ""
            or #ipa > 512 or #readable > 512 then return nil end
    if core:find("[`<>/%[%]]") or readable:find("[`<>]") then return nil end
    local readable_lower = readable:lower()
    if readable_lower:find("^i cannot") or readable_lower:find("^i can't")
            or readable_lower:find("^sorry")
            or readable_lower:find("^unable to") then return nil end
    return { ipa = "/" .. trim(core) .. "/", simple = trim(readable) }
end

function M.query(id, config, word, language, progress, request_function)
    local request = M.buildRequest(id, config, word, language)
    if not request then return nil, "not configured" end
    local response, request_error = (request_function or M.request)(request, progress)
    if not response then return nil, request_error or "request failed" end
    local text = M.extractText(request.format, response)
    local parsed = M.parseOutput(text)
    if not parsed then return nil, "invalid response" end
    parsed.provider = id
    parsed.provider_name = request.provider_name
    parsed.model = request.model
    return parsed
end

return M
