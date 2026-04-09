using HTTP

const DEFAULT_GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
const DEFAULT_GEMINI_MODEL = "gemini-1.5-pro"
const DEFAULT_OLLAMA_BASE_URL = get(ENV, "OLLAMA_BASE_URL", "http://127.0.0.1:11434")

abstract type AbstractBackend end

struct NoopBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct OllamaBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct GoogleGeminiBackend <: AbstractBackend
    config::Dict{String, Any}
end

struct CustomHTTPBackend <: AbstractBackend
    config::Dict{String, Any}
end

const BACKEND_REGISTRY = Dict{String, Dict{String, Any}}(
    "noop-stub" => Dict{String, Any}(
        "id" => "noop-stub",
        "label" => "Stub (No backend)",
        "provider" => "noop",
    ),
    "google-gemini" => Dict{String, Any}(
        "id" => "google-gemini",
        "label" => "Google Gemini",
        "provider" => "google_gemini",
        "gemini_endpoint" => DEFAULT_GEMINI_ENDPOINT,
        "gemini_model" => DEFAULT_GEMINI_MODEL,
        "google_api_key" => nothing,
        "timeout" => 60,
    ),
    "ollama-local" => Dict{String, Any}(
        "id" => "ollama-local",
        "label" => "Ollama (Local)",
        "provider" => "ollama",
        "baseUrl" => DEFAULT_OLLAMA_BASE_URL,
        "modelName" => "qwen3:4b",
    ),
    "custom_http" => Dict{String, Any}(
        "id" => "custom_http",
        "label" => "Custom HTTP Backend",
        "provider" => "custom_http",
        "base_url" => "",
        "model" => "",
        "api_key" => "",
        "headers" => Dict{String, Any}("Content-Type" => "application/json"),
        "request_template" => Dict{String, Any}(),
        "timeout" => 60,
    ),
)

const ACTIVE_BACKENDS = Dict{String, String}(
    "current" => "noop-stub",
    "brain" => "noop-stub",
    "tool" => "noop-stub",
)

function set_backend_model!(backend_id::AbstractString, model_name::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return
    BACKEND_REGISTRY[String(backend_id)]["modelName"] = String(model_name)
    BACKEND_REGISTRY[String(backend_id)]["model_name"] = String(model_name)
end

function configure_backends!(; brain_id=nothing, tool_id=nothing)
    brain_id !== nothing && set_brain_backend_id!(String(brain_id))
    tool_id !== nothing && set_tool_backend_id!(String(tool_id))
    return ACTIVE_BACKENDS
end

function set_brain_backend_id!(backend_id::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return ACTIVE_BACKENDS
    ACTIVE_BACKENDS["brain"] = String(backend_id)
    ACTIVE_BACKENDS["current"] = String(backend_id)
    return ACTIVE_BACKENDS
end

function set_tool_backend_id!(backend_id::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return ACTIVE_BACKENDS
    ACTIVE_BACKENDS["tool"] = String(backend_id)
    return ACTIVE_BACKENDS
end

function get_backend(backend_id::Union{Nothing, AbstractString}=nothing; overrides=nothing)
    target_id = backend_id === nothing ? ACTIVE_BACKENDS["current"] : String(backend_id)
    config = deepcopy(get(BACKEND_REGISTRY, target_id, BACKEND_REGISTRY["noop-stub"]))
    if overrides isa AbstractDict
        merge!(config, Dict{String, Any}(string(key) => value for (key, value) in pairs(overrides)))
    end
    provider = String(get(config, "provider", "noop"))
    if provider == "ollama"
        return OllamaBackend(config)
    elseif provider == "google_gemini"
        return GoogleGeminiBackend(config)
    elseif provider == "custom_http"
        return CustomHTTPBackend(config)
    end
    return NoopBackend(config)
end

get_brain_backend() = get_backend(ACTIVE_BACKENDS["brain"])
get_tool_backend() = get_backend(ACTIVE_BACKENDS["tool"])

function _message_content(messages)
    for message in Iterators.reverse(messages)
        if message isa AbstractDict && get(message, "role", nothing) == "user"
            return String(get(message, "content", ""))
        end
    end
    return ""
end

function generate(backend::NoopBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    user_message = _message_content(messages)
    reply = isempty(user_message) ? "[NOOP BACKEND] This is a stub response. No real model was called." : user_message
    return reply, Dict{String, Any}("provider" => "noop", "status" => "ok", "model" => "noop-stub", "options" => options)
end

function generate(backend::OllamaBackend, messages; options=Dict{String, Any}(), timeout=30)
    base_url = rstrip(String(get(backend.config, "baseUrl", "http://127.0.0.1:11434")), '/')
    model = String(get(backend.config, "modelName", "qwen3:4b"))
    payload = Dict{String, Any}(
        "model" => model,
        "messages" => messages,
        "stream" => false,
    )
    !isempty(options) && (payload["options"] = options)

    try
        response = HTTP.post("$(base_url)/api/chat", ["Content-Type" => "application/json"], JSON3.write(payload); readtimeout=timeout)
        data = _materialize_json(JSON3.read(String(response.body)))
        if haskey(data, "error")
            return "[ERROR: Ollama reported an issue. Details: $(data["error"])]", Dict{String, Any}("error" => data["error"])
        end
        message = get(get(data, "message", Dict{String, Any}()), "content", "")
        text = String(message)
        isempty(strip(text)) && return "[ERROR: The local model returned an empty response.]", Dict{String, Any}("error" => "empty_reply")
        return text, Dict{String, Any}("model" => model, "backend" => "ollama")
    catch exc
        return "[ERROR: Could not connect to Ollama.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end

function generate(backend::GoogleGeminiBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    endpoint_template = String(get(backend.config, "gemini_endpoint", DEFAULT_GEMINI_ENDPOINT))
    model = String(get(backend.config, "gemini_model", DEFAULT_GEMINI_MODEL))
    api_key = get(backend.config, "google_api_key", nothing)
    api_key = api_key === nothing || isempty(String(api_key)) ? get(ENV, "GEMINI_API_KEY", get(ENV, "GOOGLE_API_KEY", "")) : String(api_key)
    isempty(api_key) && return "[ERROR: Google Gemini API key is not set.]", Dict{String, Any}("error" => "api_key_missing")

    prompt = join(["[$(uppercase(String(get(message, "role", "user"))))] $(get(message, "content", ""))" for message in messages if message isa AbstractDict], "\n")
    endpoint = replace(endpoint_template, "{model}" => model)
    !occursin("key=", endpoint) && (endpoint *= (occursin("?", endpoint) ? "&" : "?") * "key=$(api_key)")
    payload = Dict{String, Any}("contents" => [Dict{String, Any}("parts" => [Dict{String, Any}("text" => prompt)])])
    if !isempty(options)
        generation = Dict{String, Any}()
        haskey(options, "temperature") && (generation["temperature"] = options["temperature"])
        haskey(options, "top_p") && (generation["topP"] = options["top_p"])
        !isempty(generation) && (payload["generationConfig"] = generation)
    end

    try
        response = HTTP.post(endpoint, ["Content-Type" => "application/json", "x-goog-api-key" => api_key], JSON3.write(payload); readtimeout=(timeout === nothing ? get(backend.config, "timeout", 60) : timeout))
        data = _materialize_json(JSON3.read(String(response.body)))
        text = String(data["candidates"][1]["content"]["parts"][1]["text"])
        return text, Dict{String, Any}("model" => model, "backend" => "google_gemini")
    catch exc
        return "[ERROR: Could not connect to Google Gemini.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end

function generate(backend::CustomHTTPBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    base_url = String(get(backend.config, "base_url", ""))
    isempty(base_url) && return "[ERROR: Custom HTTP backend is missing a base_url.]", Dict{String, Any}("error" => "missing_base_url")
    headers = Dict{String, String}("Content-Type" => "application/json")
    raw_headers = get(backend.config, "headers", Dict{String, Any}())
    if raw_headers isa AbstractDict
        for (key, value) in pairs(raw_headers)
            headers[String(key)] = String(value)
        end
    end
    api_key = String(get(backend.config, "api_key", ""))
    !isempty(api_key) && !haskey(headers, "Authorization") && (headers["Authorization"] = "Bearer $(api_key)")
    payload = Dict{String, Any}(
        "messages" => messages,
        "model" => get(backend.config, "model", get(backend.config, "model_name", "")),
    )
    !isempty(options) && merge!(payload, options)

    try
        response = HTTP.post(base_url, collect(pairs(headers)), JSON3.write(payload); readtimeout=(timeout === nothing ? get(backend.config, "timeout", 60) : timeout))
        data = _materialize_json(JSON3.read(String(response.body)))
        if haskey(data, "choices") && data["choices"] isa AbstractVector && !isempty(data["choices"])
            choice = data["choices"][1]
            if choice isa AbstractDict
                message = get(choice, "message", nothing)
                if message isa AbstractDict
                    return String(get(message, "content", "")), Dict{String, Any}("backend" => "custom_http", "raw" => data)
                end
            end
        end
        haskey(data, "response") && return String(data["response"]), Dict{String, Any}("backend" => "custom_http", "raw" => data)
        haskey(data, "text") && return String(data["text"]), Dict{String, Any}("backend" => "custom_http", "raw" => data)
        return "[ERROR: Custom HTTP backend returned an empty response.]", Dict{String, Any}("backend" => "custom_http", "error" => "empty_reply", "raw" => data)
    catch exc
        return "[ERROR: Custom HTTP backend request failed.]", Dict{String, Any}("error" => sprint(showerror, exc))
    end
end
