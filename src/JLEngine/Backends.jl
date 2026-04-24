using HTTP, JSON3, Base64

const DEFAULT_GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
const DEFAULT_GEMINI_MODEL = "gemini-3.1-flash-lite-preview"
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

BACKEND_REGISTRY = Dict{String, Dict{String, Any}}(
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
        "gemini_model" => "gemini-3.1-flash-lite-preview",
        "model" => "gemini-3.1-flash-lite-preview",
        "google_api_key" => nothing,
        "timeout" => 60,
    ),
    "cerebras" => Dict{String, Any}(
        "id" => "cerebras",
        "label" => "Cerebras (fast inference)",
        "provider" => "custom_http",
        "base_url" => "https://api.cerebras.ai/v1/chat/completions",
        "model" => "qwen-3-235b-a22b-instruct-2507",
        "api_key" => "",
        "env_key" => "CEREBRAS_API_KEY",
        "headers" => Dict{String, Any}("Content-Type" => "application/json"),
        "request_template" => Dict{String, Any}(),
        "timeout" => 60,
    ),
    "ollama-local" => Dict{String, Any}(
        "id" => "ollama-local",
        "label" => "Ollama (Local)",
        "provider" => "ollama",
        "baseUrl" => DEFAULT_OLLAMA_BASE_URL,
        "modelName" => "qwen3:4b",
    ),
)

# Auto-detect best available backend from env vars on boot
function _detect_default_backend()
    !isempty(get(ENV, "GEMINI_API_KEY", "")) && return "google-gemini"
    !isempty(get(ENV, "CEREBRAS_API_KEY", "")) && return "cerebras"
    return "noop-stub"
end

const _BOOT_BACKEND = _detect_default_backend()

const ACTIVE_BACKENDS = Dict{String, String}(
    "current" => _BOOT_BACKEND,
    "brain" => _BOOT_BACKEND,
    "tool" => _BOOT_BACKEND,
)

function set_backend_model!(backend_id::AbstractString, model_name::AbstractString)
    haskey(BACKEND_REGISTRY, backend_id) || return
    model_str = String(model_name)
    reg = BACKEND_REGISTRY[String(backend_id)]
    reg["modelName"] = model_str
    reg["model_name"] = model_str
    reg["model"] = model_str
    if String(backend_id) == "google-gemini"
        reg["gemini_model"] = model_str
    end
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
    # Push model name to BYTE so both paths stay in sync
    if isdefined(Main, :BYTE)
        reg = get(BACKEND_REGISTRY, backend_id, Dict())
        model = get(reg, "model",
                    get(reg, "modelName",
                        get(reg, "model_name",
                            get(reg, "gemini_model", ""))))
        !isempty(model) && Main.BYTE.set_current_model!(model)
    end
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

"""
    sync_from_byte!()

Read the current model from BYTE and ensure Backends.jl's ACTIVE_BACKENDS
and BACKEND_REGISTRY reflect it.  Call after BYTE.init / engine build and
whenever BYTE's model changes.
"""
function sync_from_byte!()
    isdefined(Main, :BYTE) || return ACTIVE_BACKENDS
    model    = Main.BYTE.get_current_model()
    provider = Main.BYTE.get_provider_for_model(model)

    backend_id = if provider == "gemini"
        reg = get(BACKEND_REGISTRY, "google-gemini", nothing)
        if reg !== nothing
            reg["gemini_model"] = model
            reg["model"] = model
            reg["model_name"] = model
            reg["modelName"] = model
        end
        "google-gemini"
    elseif haskey(BACKEND_REGISTRY, provider)
        reg = BACKEND_REGISTRY[provider]
        reg["model"] = model
        reg["model_name"] = model
        reg["modelName"] = model
        prof = Main.BYTE.get_provider_profile(provider)
        ek = get(prof, "env_key", "")
        if !isempty(ek)
            reg["env_key"] = ek
        end
        provider
    else
        prof = Main.BYTE.get_provider_profile(provider)
        ep = get(prof, "endpoint", "")
        ek = get(prof, "env_key", "")
        BACKEND_REGISTRY[provider] = Dict{String,Any}(
            "id" => provider,
            "label" => "Auto-synced: $provider",
            "provider" => "custom_http",
            "base_url" => ep,
            "model" => model,
            "api_key" => "",
            "env_key" => ek,
            "headers" => Dict{String,Any}("Content-Type" => "application/json"),
            "request_template" => Dict{String,Any}(),
            "timeout" => 90,
        )
        provider
    end

    ACTIVE_BACKENDS["brain"]   = backend_id
    ACTIVE_BACKENDS["current"] = backend_id
    @info "🔗 Backends synced from BYTE" model=model backend_id=backend_id
    return ACTIVE_BACKENDS
end

function _message_content(messages)
    for message in Iterators.reverse(messages)
        if message isa AbstractDict && get(message, "role", nothing) == "user"
            content = get(message, "content", "")
            if content isa AbstractVector
                for part in content
                    if get(part, "type", "") == "text"
                        return String(get(part, "text", ""))
                    end
                end
            end
            return String(content)
        end
    end
    return ""
end

function generate(backend::NoopBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    # Never echo the prompt back — the autopilot/UI would render that as
    # SparkByte's "thought" and show the user her own scaffolding.
    reply = "[no backend reachable]"
    return reply, Dict{String, Any}("provider" => "noop", "status" => "no_backend", "model" => "noop-stub", "options" => options)
end

function generate(backend::OllamaBackend, messages; options=Dict{String, Any}(), timeout=30)
    base_url = rstrip(String(get(backend.config, "baseUrl", DEFAULT_OLLAMA_BASE_URL)), '/')
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

function _resolve_runtime_api_key(config::AbstractDict; fallback_env_keys::AbstractVector{<:AbstractString}=String[])
    explicit = get(config, "api_key", nothing)
    if explicit !== nothing
        explicit_key = strip(String(explicit))
        !isempty(explicit_key) && return explicit_key
    end
    for env_key in fallback_env_keys
        candidate = strip(String(env_key))
        isempty(candidate) && continue
        env_value = strip(get(ENV, candidate, ""))
        !isempty(env_value) && return env_value
    end
    return ""
end

function generate(backend::GoogleGeminiBackend, messages; options=Dict{String, Any}(), timeout=nothing)
    endpoint_template = String(get(backend.config, "gemini_endpoint", DEFAULT_GEMINI_ENDPOINT))
    model = String(get(backend.config, "gemini_model", DEFAULT_GEMINI_MODEL))
    api_key = get(backend.config, "google_api_key", nothing)
    api_key = api_key === nothing || isempty(String(api_key)) ? get(ENV, "GEMINI_API_KEY", get(ENV, "GOOGLE_API_KEY", "")) : String(api_key)
    isempty(api_key) && return "[ERROR: Google Gemini API key is not set.]", Dict{String, Any}("error" => "api_key_missing")

    # Build proper Gemini multi-turn format with systemInstruction
    system_text = ""
    contents = Any[]
    for message in messages
        message isa AbstractDict || continue
        role = String(get(message, "role", "user"))
        raw_content = get(message, "content", "")
        
        parts = Any[]
        if raw_content isa AbstractVector
            for item in raw_content
                if get(item, "type", "") == "text"
                    push!(parts, Dict{String, Any}("text" => String(get(item, "text", ""))))
                elseif get(item, "type", "") == "image"
                    push!(parts, Dict{String, Any}(
                        "inlineData" => Dict{String, Any}(
                            "mimeType" => String(get(item, "mime", "image/png")),
                            "data" => String(get(item, "image", ""))
                        )
                    ))
                end
            end
        else
            content_str = if raw_content isa AbstractString
                String(raw_content)
            elseif raw_content isa AbstractDict || raw_content isa AbstractVector
                JSON3.write(raw_content)
            else
                string(raw_content)
            end
            push!(parts, Dict{String, Any}("text" => content_str))
        end
        
        if role == "system"
            # Gemini only supports text in systemInstruction
            for p in parts
                if haskey(p, "text")
                    system_text *= (isempty(system_text) ? "" : "\n") * p["text"]
                end
            end
        else
            gemini_role = role == "assistant" ? "model" : "user"
            
            # Gemini strictly requires alternating roles. Combine adjacent same-role messages.
            if !isempty(contents) && contents[end]["role"] == gemini_role
                append!(contents[end]["parts"], parts)
            else
                push!(contents, Dict{String, Any}(
                    "role" => gemini_role,
                    "parts" => parts,
                ))
            end
        end
    end

    # The Fail-Safe: If the payload is empty, return Status Code 204 to skip turn
    isempty(contents) && return "", Dict{String, Any}("status_code" => 204)

    endpoint = replace(endpoint_template, "{model}" => model)
    !occursin("key=", endpoint) && (endpoint *= (occursin("?", endpoint) ? "&" : "?") * "key=$(api_key)")

    payload = Dict{String, Any}("contents" => contents)
    !isempty(system_text) && (payload["systemInstruction"] = Dict{String, Any}(
        "parts" => Any[Dict{String, Any}("text" => system_text)],
    ))
    generation = Dict{String, Any}()
    haskey(options, "temperature") && (generation["temperature"] = options["temperature"])
    haskey(options, "top_p") && (generation["topP"] = options["top_p"])
    !isempty(generation) && (payload["generationConfig"] = generation)

    try
        response = HTTP.post(endpoint, ["Content-Type" => "application/json", "x-goog-api-key" => api_key], JSON3.write(payload); readtimeout=(timeout === nothing ? get(backend.config, "timeout", 60) : timeout))
        data = _materialize_json(JSON3.read(String(response.body)))
        text = ""
        thoughts = ""
        if haskey(data, "candidates") && !isempty(data["candidates"])
            cand = data["candidates"][1]
            if haskey(cand, "content") && haskey(cand["content"], "parts")
                for part in cand["content"]["parts"]
                    if haskey(part, "text")
                        # Gemini reasoning models tag CoT parts with thought:true.
                        # Split them out so the UI can surface the chain visibly
                        # instead of swallowing it into the final answer.
                        if get(part, "thought", false) === true
                            thoughts *= part["text"]
                        else
                            text *= part["text"]
                        end
                    end
                end
            end
        end
        meta = Dict{String, Any}("model" => model, "backend" => "google_gemini", "raw" => data)
        isempty(thoughts) || (meta["thoughts"] = thoughts)
        return text, meta
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
    env_key = String(get(backend.config, "env_key", ""))
    api_key = _resolve_runtime_api_key(backend.config; fallback_env_keys=isempty(env_key) ? String[] : [env_key])
    isempty(api_key) && return "[ERROR: Custom HTTP backend is missing an API key.]", Dict{String, Any}(
        "backend" => "custom_http",
        "error" => "api_key_missing",
        "env_key" => env_key,
    )
    !haskey(headers, "Authorization") && (headers["Authorization"] = "Bearer $(api_key)")

    model_name = get(backend.config, "model", get(backend.config, "model_name", ""))
    
    # Transform messages to OpenAI multimodal format if they are multimodal
    formatted_messages = Any[]
    for msg in messages
        role = get(msg, "role", "user")
        content = get(msg, "content", "")
        if content isa AbstractVector
            new_content = Any[]
            for item in content
                if get(item, "type", "") == "text"
                    push!(new_content, Dict("type" => "text", "text" => get(item, "text", "")))
                elseif get(item, "type", "") == "image"
                    mime = get(item, "mime", "image/png")
                    data = get(item, "image", "")
                    push!(new_content, Dict(
                        "type" => "image_url",
                        "image_url" => Dict("url" => "data:$mime;base64,$data")
                    ))
                end
            end
            push!(formatted_messages, Dict("role" => role, "content" => new_content))
        else
            push!(formatted_messages, msg)
        end
    end

    payload = Dict{String, Any}(
        "messages" => formatted_messages,
        "model" => model_name,
        "stream" => false,
    )
    !isempty(options) && merge!(payload, options)

    # Apply provider quirks from BYTE profiles when available
    if isdefined(Main, :BYTE)
        prov = Main.BYTE.get_provider_for_model(string(model_name))
        prof = Main.BYTE.get_provider_profile(prov)
        if !get(prof, "supports_top_p", true)
            delete!(payload, "top_p")
        end
        max_t = get(prof, "max_temp", nothing)
        if max_t !== nothing && haskey(payload, "temperature")
            payload["temperature"] = min(payload["temperature"], max_t)
        end
        # Cerebras gpt-oss specific reasoning/completion parameters
        if prov == "cerebras" && startswith(string(model_name), "gpt-oss")
            payload["reasoning_effort"] = "medium"
            payload["max_completion_tokens"] = 32768
        end
    end

    try
        response = HTTP.post(
            base_url,
            collect(pairs(headers)),
            JSON3.write(payload);
            readtimeout=(timeout === nothing ? get(backend.config, "timeout", 60) : timeout),
            status_exception=false,
        )
        response_text = String(response.body)
        if response.status < 200 || response.status >= 300
            return "[ERROR: Custom HTTP backend returned HTTP $(response.status).]", Dict{String, Any}(
                "backend" => "custom_http",
                "error" => "http_$(response.status)",
                "status" => response.status,
                "body" => first(strip(response_text), 500),
            )
        end
        data = _materialize_json(JSON3.read(response_text))
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
