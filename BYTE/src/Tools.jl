haskey(ENV, "JULIA_CONDAPKG_BACKEND") || (ENV["JULIA_CONDAPKG_BACKEND"] = "Null")
haskey(ENV, "JULIA_PYTHONCALL_EXE") || (ENV["JULIA_PYTHONCALL_EXE"] = "python")

using PythonCall, SQLite, DataFrames, Dates, JSON, HTTP, Base64

# Lazy-initialized singletons — set by BYTE.init()
const _state = Dict{Symbol, Any}(
    :db => nothing,
    :browser_context => nothing,
    :stealth_page => nothing,
)

# Mutable live registry for dynamically forged tools
const DYNAMIC_SCHEMA       = Dict{String,Any}[]
const _project_root        = Ref{String}("")
const _session_event_count = Ref{Int}(0)

# ── Forge event hooks — registered by BYTE on init for live dashboard broadcast ──
# Each entry is fn(name::String, code::String, description::String) -> nothing
const _FORGE_HOOKS = Function[]

# Gate for live tool forging. ON by default — forging is SparkByte's core
# capability. Operators running in shared/prod contexts can disable with
# SPARKBYTE_DISABLE_FORGE=true; the denylist in tool_forge_new_tool still
# blocks the obvious shell-escape / secret-exfil patterns either way.
function _forge_enabled()::Bool
    v = lowercase(strip(get(ENV, "SPARKBYTE_DISABLE_FORGE", "")))
    return !(v in ("1", "true", "yes", "on"))
end

# ── Live Memory Listener ──────────────────────────────────────────────────────

function _db_write_thought(context::String, thought::String, mood::String, gait::String, persona::String="SparkByte"; type::String="diary", model::String="")
    db = _state[:db]
    db === nothing && return
    try
        lock(_DB_WRITE_LOCK) do
            SQLite.execute(db,
                "INSERT INTO thoughts (timestamp, persona, context, thought, mood, gait, type, model) VALUES (?,?,?,?,?,?,?,?)",
                (string(now()), persona, first(context, 120), first(thought, 400), mood, gait, type, model))
        end
        _session_event_count[] += 1
    catch e
        @warn "Thought write failed" exception=(e, catch_backtrace())
    end
end

function _db_write_turn_snapshot(snapshot::Dict, persona::String, model::String,
                                  session_id::String, turn_number::Int,
                                  user_msg_len::Int, reply_len::Int, elapsed_ms::Int)
    db = _state[:db]
    db === nothing && return
    try
        rhythm    = get(snapshot, "rhythm",        Dict())
        aperture  = get(snapshot, "aperture_state", Dict())
        behavior  = get(snapshot, "behavior_state", Dict())
        drift     = get(snapshot, "drift",          Dict())
        advisory  = get(snapshot, "advisory",       Dict())
        lock(_DB_WRITE_LOCK) do
            SQLite.execute(db, """
                INSERT INTO turn_snapshots
                (timestamp, session_id, turn_number, persona, model,
                 gait, rhythm_mode, rhythm_momentum,
                 aperture_mode, aperture_temp, aperture_top_p,
                 behavior_state, behavior_expressiveness, behavior_pacing, behavior_tone,
                 drift_pressure, drift_temp_delta, drift_action_level,
                 advisory_bias, advisory_emotional_drift, advisory_msg,
                 user_msg_len, reply_len, elapsed_ms)
                VALUES (?,?,?,?,?, ?,?,?, ?,?,?, ?,?,?,?, ?,?,?, ?,?,?, ?,?,?)""",
                (string(now()), session_id, turn_number, persona, model,
                 string(get(snapshot, "gait", "")),
                 string(get(rhythm, "mode", "")),
                 Float64(get(rhythm, "momentum", 0.0)),
                 string(get(aperture, "mode", "")),
                 Float64(get(aperture, "temp", 0.0)),
                 Float64(get(aperture, "top_p", 0.0)),
                 string(get(behavior, "name", "")),
                 Float64(get(behavior, "expressiveness", 0.0)),
                 string(get(behavior, "pacing", "")),
                 string(get(behavior, "tone_bias", "")),
                 Float64(get(drift, "pressure", 0.0)),
                 Float64(get(drift, "temperature_delta", 0.0)),
                 string(get(drift, "action_level", "")),
                 string(get(advisory, "gating_bias", "")),
                 string(get(advisory, "emotional_drift", "")),
                 string(get(advisory, "msg", "")),
                 user_msg_len, reply_len, elapsed_ms))
        end
        _session_event_count[] += 1
    catch e
        @warn "Turn snapshot write failed" exception=(e, catch_backtrace())
    end
end

# Store raw reasoning/thinking traces from reasoning models
function _db_write_reasoning(context::String, reasoning::String, model::String, persona::String="SparkByte")
    db = _state[:db]
    db === nothing && return
    isempty(strip(reasoning)) && return
    try
        lock(_DB_WRITE_LOCK) do
            SQLite.execute(db,
                "INSERT INTO thoughts (timestamp, persona, context, thought, mood, gait, type, model) VALUES (?,?,?,?,?,?,?,?)",
                (string(now()), persona, first(context, 120), first(reasoning, 2000), "reasoning", "auto", "reasoning", model))
        end
        _session_event_count[] += 1
    catch e
        @warn "Reasoning write failed" exception=(e, catch_backtrace())
    end
end

function _db_write_tool_usage(name::String, args_json::String, result_json::String, elapsed_ms::Int, persona::String)
    db = _state[:db]
    db === nothing && return
    try
        lock(_DB_WRITE_LOCK) do
            SQLite.execute(db,
                "INSERT INTO tool_usage_log (timestamp, tool_name, args_json, result_json, duration_ms, persona, session_id) VALUES (?,?,?,?,?,?,?)",
                (string(now()), name, first(args_json, 500), first(result_json, 500), elapsed_ms, persona, isdefined(@__MODULE__, :_session_id) ? string(getfield(@__MODULE__, :_session_id)) : "unknown"))
            SQLite.execute(db, "UPDATE tools SET call_count = call_count + 1, last_used = ? WHERE name = ?", (string(now()), name))
        end
        _session_event_count[] += 1
    catch e
        @warn "Tool usage write failed" exception=(e, catch_backtrace())
    end
end

function _db_write_web_cache(url::String, content::String)
    db = _state[:db]
    db === nothing && return
    try
        summary = first(content, 300)
        lock(_DB_WRITE_LOCK) do
            existing = DBInterface.execute(db, "SELECT id FROM web_cache WHERE url = ?", (url,)) |> DataFrame
            if isempty(existing)
                SQLite.execute(db,
                    "INSERT INTO web_cache (url, fetched_at, content, summary, tags) VALUES (?,?,?,?,?)",
                    (url, string(now()), first(content, 5000), summary, "browsed"))
            else
                SQLite.execute(db,
                    "UPDATE web_cache SET fetched_at=?, content=?, summary=? WHERE url=?",
                    (string(now()), first(content, 5000), summary, url))
            end
        end
        _session_event_count[] += 1
    catch e
        @warn "Web cache write failed" url=url exception=(e, catch_backtrace())
    end
end

function _db_start_session(session_id::String)
    db = _state[:db]
    db === nothing && return
    try
        lock(_DB_WRITE_LOCK) do
            SQLite.execute(db,
                "INSERT INTO sessions (session_id, started_at, os, julia_ver, events, notes) VALUES (?,?,?,?,?,?)",
                (session_id, string(now()), string(Sys.KERNEL), string(VERSION), 0, "Boot"))
        end
    catch e
        @warn "Session start write failed" session_id=session_id exception=(e, catch_backtrace())
    end
end

function _db_end_session(session_id::String)
    db = _state[:db]
    db === nothing && return
    try
        lock(_DB_WRITE_LOCK) do
            SQLite.execute(db,
                "UPDATE sessions SET ended_at=?, events=? WHERE session_id=? AND ended_at IS NULL",
                (string(now()), _session_event_count[], session_id))
        end
    catch e
        @warn "Session end write failed" session_id=session_id exception=(e, catch_backtrace())
    end
end

# Called once at startup from BYTE.init()
function init_tools(db::SQLite.DB, browser_context, project_root::String="")
    _state[:db] = db
    _state[:browser_context] = browser_context
    _project_root[] = project_root
    if !isempty(project_root)
        _load_dynamic_tools!(project_root)
    end
end

function _runtime_state_dir(root::String="")
    configured = strip(get(ENV, "SPARKBYTE_STATE_DIR", ""))
    # Self-heal Git-Bash MSYS path mangling: inside a Linux container,
    # /app/runtime gets rewritten to C:/Program Files/Git/app/runtime by
    # the host shell before docker-compose passes env. Detect a Windows
    # drive letter while we're actually on Linux and fall back.
    if !isempty(configured) && Sys.islinux() && occursin(r"^[A-Za-z]:[\\/]"i, configured)
        configured = isdir("/app") ? "/app/runtime" : ""
    end
    base = !isempty(configured) ? configured : (!isempty(root) ? root : _project_root[])
    isempty(base) && (base = pwd())
    dir = abspath(base)
    mkpath(dir)
    return dir
end

_runtime_state_path(parts...; root::String="") = joinpath(_runtime_state_dir(root), parts...)

function _julia_command(project_root::String="")
    julia_exe = joinpath(Sys.BINDIR, Sys.iswindows() ? "julia.exe" : "julia")
    if isfile(julia_exe)
        return isempty(project_root) ? `$julia_exe` : `$julia_exe --project=$project_root`
    end
    return isempty(project_root) ? `julia` : `julia --project=$project_root`
end

"""Load previously forged tools from disk into live runtime on boot."""
function _load_dynamic_tools!(root::String)
    tools_file    = _runtime_state_path("dynamic_tools.jl"; root=root)
    registry_file = _runtime_state_path("dynamic_tools_registry.json"; root=root)

    # Eval all function definitions into BYTE module scope
    if isfile(tools_file)
        try
            exprs = Meta.parseall(read(tools_file, String))
            for expr in exprs.args
                expr isa LineNumberNode && continue
                try
                    Core.eval(@__MODULE__, expr)
                catch e
                    @warn "Dynamic tool eval failed" expr=sprint(show, expr) exception=(e, catch_backtrace())
                end
            end
        catch e
            @warn "dynamic_tools.jl load error: $e"
        end
    end

    # Rebuild TOOL_MAP + DYNAMIC_SCHEMA from registry
    if isfile(registry_file)
        try
            registry = JSON.parsefile(registry_file)
            for entry in registry
                name   = string(get(entry, "name", ""))
                fn_sym = Symbol("tool_$name")
                isempty(name) && continue
                if isdefined(@__MODULE__, fn_sym)
                    # Use invokelatest wrapper to satisfy Julia 1.12 world age semantics
                    local _sym = fn_sym
                    TOOL_MAP[name] = (args) -> Base.invokelatest(getfield(@__MODULE__, _sym), args)
                    filter!(e -> e["name"] != name, DYNAMIC_SCHEMA)
                    push!(DYNAMIC_SCHEMA, Dict{String,Any}(
                        "name"        => name,
                        "description" => string(get(entry, "description", "Dynamic tool: $name")),
                        "parameters"  => get(entry, "parameters", Dict{String,Any}(
                            "type"=>"OBJECT","properties"=>Dict{String,Any}(),"required"=>String[])),
                    ))
                end
            end
            isempty(registry) || println("⚡ Loaded $(length(registry)) dynamic tool(s): $(join([get(e,"name","?") for e in registry], ", "))")
        catch e
            @warn "dynamic tools registry load error: $e"
        end
    end
end

# --- File I/O ---
function tool_read_file(args)
    try Dict("result" => read(string(args["path"]), String))
    catch e Dict("error" => string(e)) end
end

function tool_write_file(args)
    try write(string(args["path"]), string(args["content"])); Dict("result" => "Success")
    catch e Dict("error" => string(e)) end
end

function tool_list_files(args)
    try Dict("result" => join(readdir(string(get(args, "path", "."))), "\n"))
    catch e Dict("error" => string(e)) end
end

"""Resolve JulianMetaMorph install: `JULIAN_ROOT`, then `<project>/JulianMetaMorph/JulianMetaMorph`, then legacy Desktop path."""
function _resolve_julian_root(project_root::AbstractString)::String
    env = strip(get(ENV, "JULIAN_ROOT", ""))
    !isempty(env) && isdir(env) && return env
    if !isempty(project_root)
        embedded = joinpath(project_root, "JulianMetaMorph", "JulianMetaMorph")
        isdir(embedded) && return embedded
    end
    legacy = raw"C:\Users\J_lin\Desktop\JulianMetaMorph\JulianMetaMorph"
    return isdir(legacy) ? legacy : ""
end

function _shell_command(command::String)
    if Sys.iswindows()
        # Write to a temp .ps1 file and run with -File to avoid PowerShell -Command
        # quote/escape mangling on complex strings, multi-line code, or < > $ chars.
        tmp = tempname() * ".ps1"
        write(tmp, command)
        return `powershell -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $tmp`
    end
    shell = Sys.which("bash")
    shell === nothing && (shell = Sys.which("sh"))
    shell === nothing && error("No shell found for run_command.")
    return `$shell -lc $command`
end

# --- Shell ---
function tool_run_command(args)
    tmp_ps1 = nothing
    try
        cmd_str = string(args["command"])
        # On Windows _shell_command writes a temp .ps1 — track it for cleanup
        if Sys.iswindows()
            tmp_ps1 = tempname() * ".ps1"
            write(tmp_ps1, cmd_str)
            cmd = `powershell -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $tmp_ps1`
            io = IOBuffer()
            p = run(pipeline(ignorestatus(cmd), stdout=io, stderr=io))
            out = String(take!(io))
            return Dict("result" => out, "exitcode" => p.exitcode)
        end
        io = IOBuffer()
        p = run(pipeline(ignorestatus(_shell_command(cmd_str)), stdout=io, stderr=io))
        out = String(take!(io))
        Dict("result" => out, "exitcode" => p.exitcode)
    catch e
        Dict("error" => string(e))
    finally
        tmp_ps1 !== nothing && rm(tmp_ps1; force=true)
    end
end

function tool_get_os_info(args)
    Dict("os" => string(Sys.KERNEL), "arch" => string(Sys.ARCH), "julia" => string(VERSION))
end

function tool_bluetooth_devices(args)
    action = lowercase(strip(string(get(args, "action", "list"))))
    action in ("list", "status") || return Dict("error" => "Unsupported action '$action'. Use 'list' or 'status'.")

    if Sys.iswindows()
        service = _read_shell_json("Get-Service bthserv -ErrorAction SilentlyContinue | Select-Object Status,StartType,Name | ConvertTo-Json -Compress")
        devices = _read_shell_json("Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Select-Object Status,Class,FriendlyName,InstanceId | ConvertTo-Json -Depth 4 -Compress")
        return Dict(
            "platform" => "windows",
            "action" => action,
            "service" => get(service, "data", get(service, "error", "Unavailable")),
            "devices" => get(devices, "data", get(devices, "error", "Unavailable")),
            "result" => "Bluetooth status collected from Windows service and device registry."
        )
    elseif Sys.isapple()
        profile = _read_command(`system_profiler SPBluetoothDataType -json`)
        if !get(profile, "ok", false)
            return Dict("error" => "Bluetooth inspection failed: $(get(profile, "error", "unknown error"))")
        end
        return Dict(
            "platform" => "macos",
            "action" => action,
            "profile" => try JSON.parse(get(profile, "output", "{}")) catch; get(profile, "output", "") end,
            "result" => "Bluetooth profile collected from system_profiler."
        )
    elseif Sys.islinux()
        show_res = _read_command(`bluetoothctl show`)
        list_cmd = action == "status" ? `bluetoothctl paired-devices` : `bluetoothctl devices`
        list_res = _read_command(list_cmd)
        return Dict(
            "platform" => "linux",
            "action" => action,
            "adapter" => get(show_res, "ok", false) ? get(show_res, "output", "") : get(show_res, "error", "Unavailable"),
            "devices" => get(list_res, "ok", false) ? get(list_res, "output", "") : get(list_res, "error", "Unavailable"),
            "result" => "Bluetooth information collected from bluetoothctl."
        )
    end

    Dict("error" => "Bluetooth inspection is not implemented for $(Sys.KERNEL).")
end

function _sms_twilio_config()
    sid   = strip(get(ENV, "TWILIO_ACCOUNT_SID", ""))
    token = strip(get(ENV, "TWILIO_AUTH_TOKEN", ""))
    from  = strip(get(ENV, "TWILIO_FROM_NUMBER", ""))
    missing = String[]
    isempty(sid) && push!(missing, "TWILIO_ACCOUNT_SID")
    isempty(token) && push!(missing, "TWILIO_AUTH_TOKEN")
    isempty(from) && push!(missing, "TWILIO_FROM_NUMBER")
    return (; sid, token, from, missing)
end

function _form_urlencode(pairs::Vector{Pair{String,String}})
    join(["$(HTTP.URIs.escapeuri(k))=$(HTTP.URIs.escapeuri(v))" for (k, v) in pairs], "&")
end

function _string_arg(args, key::String, env_key::String; default::String="")
    if haskey(args, key)
        value = get(args, key, default)
        value === nothing && return default
        return strip(string(value))
    end
    return strip(get(ENV, env_key, default))
end

_strip_trailing_slash(value::AbstractString) = endswith(value, "/") ? chop(String(value); tail=1) : String(value)

function _reddit_submit_config(args)
    subreddit = replace(_string_arg(args, "subreddit", "REDDIT_SUBREDDIT"), r"^/?r/" => "")
    kind = lowercase(strip(string(get(args, "kind", ""))))
    kind == "text" && (kind = "self")

    text = string(get(args, "text", ""))
    url  = _string_arg(args, "url", "REDDIT_URL")
    if isempty(kind) || kind == "auto"
        kind = !isempty(strip(text)) ? "self" : !isempty(strip(url)) ? "link" : ""
    end

    return (;
        subreddit = strip(subreddit),
        title = _string_arg(args, "title", "REDDIT_TITLE"),
        text = text,
        url = url,
        kind = kind,
        dry_run = _looks_true(get(args, "dry_run", false)),
        user_agent = _string_arg(args, "user_agent", "REDDIT_USER_AGENT"; default="SparkByte/1.0 (by u/yourusername)"),
        access_token = _string_arg(args, "access_token", "REDDIT_ACCESS_TOKEN"),
        client_id = _string_arg(args, "client_id", "REDDIT_CLIENT_ID"),
        client_secret = _string_arg(args, "client_secret", "REDDIT_CLIENT_SECRET"),
        refresh_token = _string_arg(args, "refresh_token", "REDDIT_REFRESH_TOKEN"),
        api_base = _strip_trailing_slash(_string_arg(args, "api_base", "REDDIT_API_BASE"; default="https://oauth.reddit.com")),
        auth_base = _strip_trailing_slash(_string_arg(args, "auth_base", "REDDIT_AUTH_BASE"; default="https://www.reddit.com")),
        flair_id = _string_arg(args, "flair_id", "REDDIT_FLAIR_ID"),
        flair_text = _string_arg(args, "flair_text", "REDDIT_FLAIR_TEXT"),
        sendreplies = _looks_true(get(args, "sendreplies", true), default=true),
        nsfw = _looks_true(get(args, "nsfw", false)),
        spoiler = _looks_true(get(args, "spoiler", false)),
        resubmit = _looks_true(get(args, "resubmit", false)),
    )
end

function _reddit_access_token(cfg)
    if !isempty(cfg.access_token)
        return Dict("token" => cfg.access_token, "source" => "access_token")
    end

    missing = String[]
    isempty(cfg.client_id) && push!(missing, "REDDIT_CLIENT_ID")
    isempty(cfg.refresh_token) && push!(missing, "REDDIT_REFRESH_TOKEN")
    if !isempty(missing)
        return Dict(
            "error" => "Reddit auth is not configured. Missing: $(join(missing, ", ")).",
            "missing_env" => missing,
        )
    end

    auth = base64encode("$(cfg.client_id):$(cfg.client_secret)")
    body = _form_urlencode([
        "grant_type" => "refresh_token",
        "refresh_token" => cfg.refresh_token,
    ])
    headers = [
        "Authorization" => "Basic $auth",
        "Content-Type" => "application/x-www-form-urlencoded",
        "User-Agent" => cfg.user_agent,
    ]

    try
        resp = HTTP.post("$(cfg.auth_base)/api/v1/access_token", headers, body; status_exception=false)
        body_text = String(resp.body)
        if resp.status < 200 || resp.status >= 300
            return Dict(
                "error" => "Reddit token request failed with HTTP $(resp.status).",
                "body" => first(body_text, 500),
            )
        end

        parsed = try JSON.parse(body_text) catch; Dict{String,Any}() end
        token = string(get(parsed, "access_token", ""))
        isempty(token) && return Dict(
            "error" => "Reddit token response missing access_token.",
            "body" => first(body_text, 500),
        )

        return Dict(
            "token" => token,
            "source" => "refresh_token",
            "expires_in" => get(parsed, "expires_in", nothing),
            "scope" => get(parsed, "scope", ""),
            "token_type" => get(parsed, "token_type", ""),
        )
    catch e
        return Dict("error" => "Reddit token request failed: $(string(e))")
    end
end

function tool_send_sms(args)
    provider = lowercase(strip(string(get(args, "provider", "twilio"))))
    provider == "twilio" || return Dict("error" => "Unsupported SMS provider '$provider'. Only 'twilio' is implemented right now.")

    to = strip(string(get(args, "to", "")))
    body = string(get(args, "message", get(args, "body", "")))
    from_override = strip(string(get(args, "from", "")))
    dry_run = _looks_true(get(args, "dry_run", false))

    isempty(to) && return Dict("error" => "Missing required field: to")
    isempty(strip(body)) && return Dict("error" => "Missing required field: message")

    cfg = _sms_twilio_config()
    from_number = isempty(from_override) ? cfg.from : from_override
    if !dry_run && !isempty(cfg.missing)
        return Dict(
            "error" => "Twilio SMS is not configured. Missing: $(join(cfg.missing, ", "))",
            "missing_env" => cfg.missing
        )
    end

    preview = Dict(
        "provider" => provider,
        "to" => to,
        "from" => from_number,
        "message_preview" => first(body, 160),
        "configured" => isempty(cfg.missing)
    )
    dry_run && return merge(Dict("result" => "SMS dry run only. No message was sent."), preview)

    url = "https://api.twilio.com/2010-04-01/Accounts/$(cfg.sid)/Messages.json"
    form = _form_urlencode([
        "To" => to,
        "From" => from_number,
        "Body" => body,
    ])
    auth = base64encode("$(cfg.sid):$(cfg.token)")
    headers = [
        "Authorization" => "Basic $auth",
        "Content-Type" => "application/x-www-form-urlencoded",
    ]

    try
        resp = HTTP.post(url, headers, form)
        body_text = String(resp.body)
        if 200 <= resp.status < 300
            data = JSON.parse(body_text)
            return merge(Dict(
                "result" => "SMS request accepted by Twilio.",
                "status" => get(data, "status", ""),
                "sid" => get(data, "sid", ""),
            ), preview)
        end
        return Dict(
            "error" => "Twilio rejected the SMS request with HTTP $(resp.status).",
            "details" => first(body_text, 500)
        )
    catch e
        Dict("error" => "SMS send failed: $(string(e))")
    end
end

# --- Code Execution ---
const _JULIA_SQLITE_PREAMBLE = raw"""
# ── SparkByte SQLite compatibility shim ──────────────────────────────────────
# Use query_db(db, sql) or query_db(db, sql, params) instead of SQLite.execute.
# Returns a DataFrames.DataFrame so column access works: df.colname or df[!,:col]
import SQLite, DataFrames, DBInterface, Dates, JSON, Statistics
function query_db(db::SQLite.DB, sql::String, params=())
    isempty(params) ?
        DBInterface.execute(db, sql) |> DataFrames.DataFrame :
        DBInterface.execute(db, sql, params) |> DataFrames.DataFrame
end
# ─────────────────────────────────────────────────────────────────────────────
"""

function tool_execute_code(args)
    try
        lang = string(get(args, "language", "julia"))
        code = string(args["code"])
        ext  = lang == "python" ? ".py" : ".jl"
        tmp  = tempname() * ext
        root = isempty(_project_root[]) ? pwd() : _project_root[]
        # For Julia, prepend the compatibility shim so AI-generated code can
        # safely use query_db(db, sql) and gets DataFrames back, not raw Int32.
        final_code = lang == "julia" ? _JULIA_SQLITE_PREAMBLE * "\n" * code : code
        write(tmp, final_code)
        cmd = lang == "python" ? `python $tmp` : `$(_julia_command(root)) $tmp`

        io = IOBuffer()
        p = run(pipeline(ignorestatus(cmd), stdout=io, stderr=io))
        out = String(take!(io))
        rm(tmp; force=true)
        Dict("stdout" => out, "exitcode" => p.exitcode)
    catch e
        Dict("error" => string(e))
    end
end

# ── Core Engine Rule Enforcement ─────────────────────────────────────────────

# Packages actually installed in BYTE/Project.toml + Julia stdlib
const _ALLOWED_PACKAGES = Set([
    "SQLite","JSON","HTTP","DataFrames","Dates","PythonCall",
    "Printf","Base64","SHA","Statistics","LinearAlgebra","Random",
    "Base","Core","InteractiveUtils","Logging",
])

# Capabilities SparkByte genuinely does NOT have
const _PHANTOM_CAPABILITIES = [
    (r"microphone|audio_input|record_audio|listen_mic"i,        "microphone / audio input"),
    (r"\bcamera\b|\bwebcam\b|take_photo|capture_image"i,        "camera / webcam"),
    (r"\bgpio\b|raspberry_pi|arduino|serial_port"i,             "GPIO / hardware serial"),
    (r"send_email|smtp|sendmail|SMTP"i,                         "email sending (no SMTP configured)"),
    (r"gpu_temp|nvml|cuda_device|CuArray|CUDA\."i,              "GPU / CUDA (not available)"),
    (r"NFC|rfid|fingerprint_reader"i,                           "NFC / biometric hardware"),
]

function _looks_true(value; default::Bool=false)
    value === nothing && return default
    value isa Bool && return value
    normalized = lowercase(strip(string(value)))
    return !(normalized in ("", "0", "false", "no", "off"))
end

function _read_command(cmd::Cmd)
    try
        Dict("ok" => true, "output" => strip(read(cmd, String)))
    catch e
        Dict("ok" => false, "error" => string(e))
    end
end

function _read_shell_json(command::String)
    result = _read_command(_shell_command(command))
    get(result, "ok", false) || return result
    output = get(result, "output", "")
    isempty(output) && return Dict("ok" => true, "data" => Any[])
    try
        return Dict("ok" => true, "data" => JSON.parse(output))
    catch
        return Dict("ok" => true, "data" => output)
    end
end

"""
    _validate_forge_code(name, code) -> Vector{String}

Rule 1 enforcement: scan forged tool code for capabilities SparkByte doesn't have.
Returns a list of violation strings (empty = clean).
"""
function _validate_forge_code(name::String, code::String)
    errors = String[]

    # 1a. Any `tool_X(` call must reference a tool that exists in TOOL_MAP
    for m in eachmatch(r"\btool_([a-z_0-9]+)\s*\(", code)
        tname = m.captures[1]
        tname == name && continue   # self-reference / recursion is fine
        if !haskey(TOOL_MAP, tname)
            push!(errors, "Calls `tool_$(tname)()` but that tool does not exist. " *
                          "Available tools: $(join(sort(collect(keys(TOOL_MAP))), ", ")).")
        end
    end

    # 1b. Phantom hardware / capability patterns
    for (pat, label) in _PHANTOM_CAPABILITIES
        occursin(pat, code) && push!(errors,
            "References '$label' — SparkByte does not have this capability.")
    end

    # 1c. `using X` or `using X, Y, Z` must all be allowed packages
    for m in eachmatch(r"\busing\s+([A-Za-z][A-Za-z0-9_.,: ]*)", code)
        for pkg in split(m.captures[1], r"[,\s:.]+")
            pkg = strip(pkg)
            isempty(pkg) && continue
            pkg == "using" && continue          # keyword bleed — skip
            !occursin(r"^[A-Za-z][A-Za-z0-9_]*$", pkg) && continue  # not a bare identifier
            pkg ∈ _ALLOWED_PACKAGES && continue
            startswith(pkg, "Base") && continue
            push!(errors, "Imports '$pkg' which is not installed in Julia. " *
                          "Available: $(join(sort(collect(_ALLOWED_PACKAGES)), ", ")).")
        end
    end

    errors
end

# --- Dynamic Tool Forge ---
"""
Forge a new Julia tool into the live runtime.

The `code` arg MUST define a function named `tool_<name>(args)` where args is a Dict.
Example:
  name: "greet_user"
  code: |
    function tool_greet_user(args)
        name = get(args, "name", "stranger")
        Dict("result" => "Hey \$name, SparkByte says hi!")
    end
  description: "Greet a user by name"
  parameters: {"type":"OBJECT","properties":{"name":{"type":"STRING","description":"User name"}},"required":["name"]}
"""
function tool_forge_new_tool(args)
    try
        name        = string(args["name"])
        code        = string(args["code"])
        description = string(get(args, "description", "Dynamically forged tool: $name"))
        parameters  = get(args, "parameters", Dict{String,Any}(
            "type"=>"OBJECT","properties"=>Dict{String,Any}(),"required"=>String[]))
        root        = _project_root[]

        # ── Forge gate — live Core.eval into the runtime module. ON by default
        # because this is SparkByte's core capability. Operators running in
        # shared/prod contexts can opt out with SPARKBYTE_DISABLE_FORGE=true.
        if !_forge_enabled()
            return Dict("error" => "FORGE DISABLED — SPARKBYTE_DISABLE_FORGE is set on this " *
                "server. Forging is off in this environment.")
        end

        # Deny-list patterns that escape the tool sandbox. Best-effort, not a
        # substitute for process-level isolation, but catches the obvious cases.
        forge_denylist = (
            ("run(`rm "          , "shell rm"),
            ("run(`del "         , "shell del"),
            ("rm("               , "filesystem rm()"),
            ("Base.remove_"      , "Base.remove_*"),
            ("include("          , "arbitrary include()"),
            ("eval("             , "nested eval()"),
            ("Core.eval"         , "nested Core.eval"),
            ("ENV[\"OPENAI_API_KEY"     , "key exfiltration"),
            ("ENV[\"GEMINI_API_KEY"     , "key exfiltration"),
            ("ENV[\"XAI_API_KEY"        , "key exfiltration"),
            ("ENV[\"CEREBRAS_API_KEY"   , "key exfiltration"),
            ("ENV[\"OPENROUTER_API_KEY" , "key exfiltration"),
            ("ENV[\"AZURE_AI_API_KEY"   , "key exfiltration"),
            ("ENV[\"STRIPE_"     , "stripe key exfiltration"),
            ("ENV[\"A2A_ADMIN"   , "admin key exfiltration"),
        )
        blocked = [label for (pat, label) in forge_denylist if occursin(pat, code)]
        if !isempty(blocked)
            return Dict("error" => "FORGE REJECTED — forbidden pattern: $(join(blocked, ", ")). " *
                "Forge is allowed for new tool functions only, not for shell escape, filesystem wipe, nested eval, or secret exfiltration.")
        end

        # ── Rule 1 is now NO DECEPTION — attempt is allowed, live test proves it ──
        # Phantom hardware check still applies (no faking microphone, camera, etc.)
        hw_violations = filter(v -> any(occursin(pat, code) for (pat, _) in _PHANTOM_CAPABILITIES),
                               [label for (pat, label) in _PHANTOM_CAPABILITIES if occursin(pat, code)])
        if !isempty(hw_violations)
            return Dict("error" => "FORGE REJECTED — hardware you cannot access: $(join(hw_violations, ", ")). " *
                "Do not fake hardware capabilities. Return a real error if the device isn't available.")
        end

        # 0a. Pre-eval JETLS-style validation — parse + lower every expression
        # before any side effects. Catches syntax errors, scope violations,
        # malformed expressions. Cheap and doesn't require JET.jl as a hard dep.
        # JET-proper runs post-eval (step 2.5) when the package is available.
        parsed = try
            Meta.parseall(code)
        catch e
            return Dict("error" => "FORGE REJECTED — parse failure: $(e)", "stage" => "parse")
        end
        for expr in parsed.args
            expr isa LineNumberNode && continue
            (expr isa Expr && expr.head in (:using, :import)) && continue
            lowered = Meta.lower(@__MODULE__, expr)
            if lowered isa Expr && lowered.head === :error
                return Dict("error" => "FORGE REJECTED — lower failure: $(lowered.args[1])", "stage" => "lower")
            end
        end

        # 1. Eval code into BYTE module — live immediately
        # Iterate per-expression (same as _load_dynamic_tools!) so that top-level
        # `using` statements (packages already in scope) don't trigger world-age
        # recursion in Julia 1.12 when eval'd as a single :toplevel block.
        for expr in parsed.args
            expr isa LineNumberNode && continue
            (expr isa Expr && expr.head in (:using, :import)) && continue
            Core.eval(@__MODULE__, expr)
        end

        # 2. Verify expected function exists
        fn_sym = Symbol("tool_$name")
        if !isdefined(@__MODULE__, fn_sym)
            return Dict("error" => "Eval succeeded but `tool_$name(args)` not found. Code must define exactly that function name.")
        end

        # 2.5. JET deep-check (soft dep). If JET.jl is loaded, run abstract
        # interpretation against the new function for a Dict{String,Any} arg.
        # Reports type errors, undef vars, dispatch failures the parser misses.
        # Skipped silently if JET isn't available — never fails the forge for
        # warnings, only logs and stamps the schema with a quality flag.
        jet_report = ""
        try
            jet_mod = isdefined(@__MODULE__, :JET) ? getfield(@__MODULE__, :JET) :
                      (Base.find_package("JET") !== nothing ? Base.require(Base.PkgId(Base.UUID("c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"), "JET")) : nothing)
            if jet_mod !== nothing
                fn = getfield(@__MODULE__, fn_sym)
                rep = Base.invokelatest(jet_mod.report_call, fn, (Dict{String,Any},))
                jet_report = string(rep)
                if occursin(r"\d+ possible error"i, jet_report)
                    @warn "Forged tool `$name` has JET-detected issues" report=first(jet_report, 800)
                end
            end
        catch e
            @debug "JET check skipped" exception=e
        end

        # 3. Register in TOOL_MAP with invokelatest wrapper for Julia 1.12 world age compliance
        local _sym = fn_sym
        TOOL_MAP[name] = (args) -> Base.invokelatest(getfield(@__MODULE__, _sym), args)

        # 4. Update DYNAMIC_SCHEMA (upsert)
        filter!(e -> e["name"] != name, DYNAMIC_SCHEMA)
        push!(DYNAMIC_SCHEMA, Dict{String,Any}(
            "name"        => name,
            "description" => description,
            "parameters"  => parameters,
        ))

        if !isempty(root)
            tools_path    = _runtime_state_path("dynamic_tools.jl"; root=root)
            registry_path = _runtime_state_path("dynamic_tools_registry.json"; root=root)
            test_dir      = joinpath(root, "test")
            test_file     = joinpath(test_dir, "test_dynamic_tools.jl")

            # 5. Persist code — replace existing block if re-forging
            existing_code = isfile(tools_path) ? read(tools_path, String) : ""
            marker        = "# -- Tool: $name --"
            if occursin(marker, existing_code)
                # Strip old block
                lines  = split(existing_code, "\n")
                in_blk = false
                kept   = String[]
                for ln in lines
                    if startswith(ln, marker)
                        in_blk = true; continue
                    elseif in_blk && startswith(ln, "# -- Tool:")
                        in_blk = false
                    end
                    in_blk || push!(kept, ln)
                end
                existing_code = join(kept, "\n")
            end
            open(tools_path, "w") do f
                write(f, rstrip(existing_code))
                write(f, "\n\n$marker\n$code\n")
            end

            # 6. Update registry JSON
            registry = isfile(registry_path) ?
                try JSON.parsefile(registry_path) catch; Any[] end : Any[]
            filter!(e -> get(e, "name", "") != name, registry)
            push!(registry, Dict{String,Any}(
                "name"=>name, "description"=>description, "parameters"=>parameters))
            write(registry_path, JSON.json(registry, 2))

            # 7. Run the tool live in the runtime with args from schema
            # If it fails, return error so the agentic loop re-forges with a fix
            live_args = Dict{String,Any}()
            if parameters isa Dict
                for req in get(parameters, "required", [])
                    prop = get(get(parameters, "properties", Dict()), req, Dict())
                    typ  = get(prop, "type", "STRING")
                    live_args[req] = typ == "INTEGER" ? 0 : typ == "BOOLEAN" ? false : "test"
                end
            end
            live_result = try
                Base.invokelatest(getfield(@__MODULE__, fn_sym), live_args)
            catch e
                Dict("error" => string(e))
            end
            live_ok = live_result isa Dict && !haskey(live_result, "error")

            # Log real result to test file
            mkpath(test_dir)
            entry = """
# -- tool_$name | $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS")) | $(live_ok ? "PASS" : "FAIL") --
# args:   $(JSON.json(live_args))
# result: $(JSON.json(live_result))
"""
            open(test_file, "a") do f; write(f, entry); end

            # If it failed, signal back so the loop re-forges
            if !live_ok
                live_err = get(live_result, "error", "unknown")
                return Dict(
                    "error"        => "Tool '$name' forged but failed live test: $live_err",
                    "forge_broken" => true,
                    "tool_name"    => name,
                    "hint"         => "Fix the code and re-forge. Test args used: $(JSON.json(live_args))",
                    "live_result"  => live_result,
                )
            end
        end

        # ── Fire forge hooks (live dashboard broadcast, etc.) ────────────────
        for hook in _FORGE_HOOKS
            try; hook(name, code, description); catch e; @warn "Forge hook failed" exception=(e, catch_backtrace()); end
        end

        Dict("result" => "Tool '$name' is LIVE. Eval succeeded — registered in dispatch, logged to test file.")
    catch e
        bt = sprint(showerror, e, catch_backtrace())
        Dict("error" => "Forge failed: $(first(string(e), 400))", "stacktrace" => first(bt, 800))
    end
end

# --- GitHub Pillage ---
# Converts a github.com file URL to raw.githubusercontent.com
function _github_to_raw(url::String)
    m = match(r"https?://github\.com/([^/]+)/([^/]+)/blob/(.+)", url)
    m === nothing && return nothing
    "https://raw.githubusercontent.com/$(m[1])/$(m[2])/$(m[3])"
end

# Returns (owner, repo, ref, subpath) for a github.com tree URL, or nothing
function _parse_github_tree(url::String)
    m = match(r"https?://github\.com/([^/]+)/([^/]+)(?:/tree/([^/]+)(/.*)?)?$", url)
    m === nothing && return nothing
    (m[1], m[2], something(m[3], "HEAD"), something(m[4], ""))
end

function tool_github_pillage(args)
    url      = string(get(args, "url", ""))
    write_to = get(args, "write_to", nothing)
    isempty(url) && return Dict("error" => "url is required")

    headers = ["User-Agent" => "SparkByte/1.0"]

    # ── Direct raw URL ───────────────────────────────────────────────────────
    if contains(url, "raw.githubusercontent.com")
        try
            resp = HTTP.get(url, headers)
            content = String(resp.body)
            if write_to !== nothing && !isempty(write_to)
                mkpath(dirname(write_to))
                write(write_to, content)
                return Dict("written" => write_to, "bytes" => length(content))
            end
            return Dict("content" => content, "bytes" => length(content))
        catch e; return Dict("error" => string(e)) end
    end

    # ── github.com /blob/ file URL → raw content ─────────────────────────────
    raw_url = _github_to_raw(url)
    if raw_url !== nothing
        try
            resp = HTTP.get(raw_url, headers)
            content = String(resp.body)
            if write_to !== nothing && !isempty(write_to)
                mkpath(dirname(write_to))
                write(write_to, content)
                return Dict("written" => write_to, "bytes" => length(content), "source" => raw_url)
            end
            return Dict("content" => content, "bytes" => length(content), "source" => raw_url)
        catch e; return Dict("error" => string(e)) end
    end

    # ── github.com repo or tree URL → file listing via API ───────────────────
    parsed = _parse_github_tree(url)
    if parsed !== nothing
        owner, repo, ref, subpath = parsed
        api_url = "https://api.github.com/repos/$owner/$repo/git/trees/$ref?recursive=1"
        try
            resp = HTTP.get(api_url, [headers..., "Accept" => "application/vnd.github+json"])
            data = JSON.parse(String(resp.body))
            tree = get(data, "tree", [])
            prefix = lstrip(subpath, '/')
            files = [t["path"] for t in tree
                     if t["type"] == "blob" && startswith(t["path"], prefix)]
            return Dict("files" => files, "count" => length(files),
                        "repo" => "$owner/$repo", "ref" => ref,
                        "tip" => "Use github_pillage with the full blob URL to fetch any file, or pass write_to to save it.")
        catch e; return Dict("error" => string(e)) end
    end

    # ── Fallback: treat as raw HTTP fetch (gist, etc.) ───────────────────────
    try
        resp = HTTP.get(url, headers)
        content = String(resp.body)
        if write_to !== nothing && !isempty(write_to)
            mkpath(dirname(write_to))
            write(write_to, content)
            return Dict("written" => write_to, "bytes" => length(content))
        end
        return Dict("content" => first(content, 8000), "bytes" => length(content))
    catch e; return Dict("error" => string(e)) end
end

# --- Web Eyes ---
# Primary web reader: Jina Reader returns clean LLM-ready markdown for any URL
# without spinning up a browser. Use this first; fall back to browse_url /
# playwright_interact only for JS-heavy SPAs, auth-walled pages, or interaction.
function tool_jina_fetch(args)
    url = string(get(args, "url", ""))
    isempty(url) && return Dict("error" => "url required")
    max_chars = Int(get(args, "max_chars", 8000))
    target = "https://r.jina.ai/" * url
    headers = ["Accept" => "text/plain", "User-Agent" => "SparkByte/1.0"]
    api_key = get(ENV, "JINA_API_KEY", "")
    isempty(api_key) || push!(headers, "Authorization" => "Bearer " * api_key)
    try
        resp = HTTP.get(target, headers; readtimeout=30, retry=false, status_exception=false)
        body = String(resp.body)
        if resp.status >= 400
            return Dict("error" => "Jina fetch failed (HTTP $(resp.status))", "hint" => "Try browse_url or playwright_interact for JS/auth pages.", "body" => first(body, 500))
        end
        @async try; _db_write_web_cache(url, body); catch e; @warn "Web cache write failed" exception=(e, catch_backtrace()); end
        Dict("content" => first(body, max_chars), "source" => "jina_reader", "url" => url, "truncated" => length(body) > max_chars)
    catch e
        Dict("error" => string(e), "hint" => "Network error — try browse_url as fallback.")
    end
end

function tool_browse_url(args)
    ctx = _state[:browser_context]
    ctx === nothing && return Dict("error" => "Browser not initialized.")
    url = string(args["url"])
    # Redirect bare google searches to DuckDuckGo — Google aggressively flags
    # headless traffic with captcha walls even with stealth patches applied.
    redirected = false
    if occursin(r"^https?://(www\.)?google\.com/search"i, url)
        q = match(r"[?&]q=([^&]+)", url)
        if q !== nothing
            url = "https://duckduckgo.com/?q=" * q.captures[1]
            redirected = true
        end
    end
    try
        page = ctx.new_page()
        try
            page.goto(url, wait_until="domcontentloaded", timeout=20000)
            try; page.wait_for_load_state("networkidle", timeout=5000); catch; end
        catch e
            # retry with laxer wait
            try; page.goto(url, wait_until="load", timeout=15000); catch; end
        end
        text = pyconvert(String, page.evaluate("() => document.body.innerText"))
        final_url = pyconvert(String, page.url)
        page.close()
        # Detect captcha / bot-wall pages and surface clearly.
        bot_wall = occursin(r"unusual traffic|are you a robot|captcha|/sorry/"i, text) ||
                   occursin(r"/sorry/"i, final_url)
        @async try; _db_write_web_cache(url, text); catch e; @warn "Web cache write failed" exception=(e, catch_backtrace()); end
        out = Dict{String,Any}("content" => first(text, 5000), "final_url" => final_url)
        redirected && (out["note"] = "Redirected Google search → DuckDuckGo to bypass bot wall.")
        bot_wall && (out["warning"] = "Target served a captcha / bot-detection page. Content may be useless.")
        out
    catch e Dict("error" => string(e)) end
end

# ── Stealth Browser (persistent page, screenshot-based) ──────────────────────
# Maintains a single long-lived Playwright page so cookies/session survive
# across navigations in the stealth browser panel.

const _STEALTH_VIEWPORT_W = 1280
const _STEALTH_VIEWPORT_H = 800
const _STEALTH_SS_PATH    = Ref{String}("")

function _stealth_ss_path()
    if isempty(_STEALTH_SS_PATH[])
        _STEALTH_SS_PATH[] = joinpath(tempdir(), "sparkbyte_stealth.png")
    end
    _STEALTH_SS_PATH[]
end

function _get_stealth_page()
    ctx = _state[:browser_context]
    ctx === nothing && error("Browser context not initialized.")
    pg = _state[:stealth_page]
    # Recreate if page is closed/null
    if pg === nothing || pyconvert(Bool, pg.is_closed())
        pg = ctx.new_page()
        pg.set_viewport_size(Dict("width"=>_STEALTH_VIEWPORT_W, "height"=>_STEALTH_VIEWPORT_H))
        _state[:stealth_page] = pg
    end
    pg
end

function _stealth_snapshot()
    pg = _get_stealth_page()
    ss = _stealth_ss_path()
    try
        pg.screenshot(path=ss, type="png")
        b64 = base64encode(read(ss))
        url = pyconvert(String, pg.url)
        title = try; pyconvert(String, pg.title()); catch; ""; end
        return Dict{String,Any}("img_b64"=>b64, "url"=>url, "title"=>title,
            "w"=>_STEALTH_VIEWPORT_W, "h"=>_STEALTH_VIEWPORT_H)
    catch e
        return Dict{String,Any}("error"=>string(e))
    end
end

function tool_stealth_nav(args)
    ctx = _state[:browser_context]
    ctx === nothing && return Dict("error" => "Browser not initialized.")
    url = string(get(args, "url", ""))
    isempty(url) && return Dict("error" => "url required")
    try
        pg = _get_stealth_page()
        try; pg.goto(url, wait_until="domcontentloaded", timeout=22000); catch; end
        try; pg.wait_for_load_state("networkidle", timeout=5000); catch; end
        _stealth_snapshot()
    catch e; Dict("error"=>string(e)) end
end

function tool_stealth_act(args)
    ctx = _state[:browser_context]
    ctx === nothing && return Dict("error" => "Browser not initialized.")
    action = string(get(args, "action", "screenshot"))
    try
        pg = _get_stealth_page()
        if action == "click_xy"
            x = Float64(get(args, "x", 0))
            y = Float64(get(args, "y", 0))
            pg.mouse.click(x, y)
            try; pg.wait_for_load_state("networkidle", timeout=4000); catch; end
        elseif action == "back"
            pg.go_back(wait_until="domcontentloaded", timeout=10000)
            try; pg.wait_for_load_state("networkidle", timeout=4000); catch; end
        elseif action == "forward"
            pg.go_forward(wait_until="domcontentloaded", timeout=10000)
            try; pg.wait_for_load_state("networkidle", timeout=4000); catch; end
        elseif action == "scroll"
            dy = Float64(get(args, "dy", 300))
            pg.mouse.wheel(0, dy)
            sleep(0.3)
        elseif action == "type_at"
            x = Float64(get(args, "x", 0))
            y = Float64(get(args, "y", 0))
            text = string(get(args, "text", ""))
            pg.mouse.click(x, y)
            pg.keyboard.type(text)
        elseif action == "key"
            key = string(get(args, "key", ""))
            isempty(key) || pg.keyboard.press(key)
            try; pg.wait_for_load_state("networkidle", timeout=4000); catch; end
        elseif action == "refresh"
            pg.reload(wait_until="domcontentloaded", timeout=20000)
            try; pg.wait_for_load_state("networkidle", timeout=4000); catch; end
        end
        _stealth_snapshot()
    catch e; Dict("error"=>string(e)) end
end

# --- Memory ---
function tool_remember(args)
    db = _state[:db]
    db === nothing && return Dict("error" => "DB not initialized.")
    SQLite.execute(db,
        "INSERT INTO memory (timestamp, tag, key, content) VALUES (?, ?, ?, ?)",
        (string(now()), get(args, "tag", "gen"), get(args, "key", ""), string(args["content"])))
    Dict("result" => "Stored.")
end

function tool_recall(args)
    db = _state[:db]
    db === nothing && return Dict("error" => "DB not initialized.")
    q    = string(get(args, "query", ""))
    mode = string(get(args, "mode",  "memory"))  # memory | behavior_states | personas | knowledge | tools | telemetry | thoughts

    pq = "%$q%"  # parameterized LIKE value

    if mode == "behavior_states"
        rows = isempty(q) ?
            DBInterface.execute(db,
                "SELECT state_id, name, intensity, control, expressiveness, pacing, tone_bias, memory_strictness FROM behavior_states ORDER BY intensity, control") |> DataFrame :
            DBInterface.execute(db,
                "SELECT state_id, name, intensity, control, expressiveness, pacing, tone_bias, memory_strictness FROM behavior_states WHERE name LIKE ? OR tone_bias LIKE ? OR pacing LIKE ? ORDER BY intensity, control",
                (pq, pq, pq)) |> DataFrame
        isempty(rows) && return Dict("result" => "No behavior states found.")
        lines = ["$(r.state_id) | $(r.name) | intensity=$(r.intensity) control=$(r.control) expr=$(r.expressiveness) pacing=$(r.pacing) tone=$(r.tone_bias) mem=$(r.memory_strictness)"
                 for r in eachrow(rows)]
        return Dict("result" => join(lines, "\n"), "count" => nrow(rows))

    elseif mode == "personas"
        rows = isempty(q) ?
            DBInterface.execute(db,
                "SELECT name, description, tone, boot_prompt, active FROM personas ORDER BY active DESC, name") |> DataFrame :
            DBInterface.execute(db,
                "SELECT name, description, tone, boot_prompt, active FROM personas WHERE name LIKE ? OR description LIKE ? OR tone LIKE ? ORDER BY active DESC, name",
                (pq, pq, pq)) |> DataFrame
        isempty(rows) && return Dict("result" => "No personas found.")
        lines = ["$(r.active==1 ? "★" : " ") $(r.name) | $(r.tone) | $(first(string(r.description),120))"
                 for r in eachrow(rows)]
        return Dict("result" => join(lines, "\n"), "count" => nrow(rows))

    elseif mode == "knowledge"
        rows = isempty(q) ?
            DBInterface.execute(db,
                "SELECT domain, topic, content FROM knowledge ORDER BY domain, topic LIMIT 200") |> DataFrame :
            DBInterface.execute(db,
                "SELECT domain, topic, content FROM knowledge WHERE domain LIKE ? OR topic LIKE ? OR content LIKE ? ORDER BY domain, topic LIMIT 200",
                (pq, pq, pq)) |> DataFrame
        isempty(rows) && return Dict("result" => "No knowledge entries found for: $q")
        lines = ["[$(r.domain)/$(r.topic)]: $(first(string(r.content), 200))" for r in eachrow(rows)]
        return Dict("result" => join(lines, "\n"), "count" => nrow(rows))

    elseif mode == "tools"
        rows = isempty(q) ?
            DBInterface.execute(db,
                "SELECT name, description, is_dynamic, call_count, last_used FROM tools ORDER BY is_dynamic DESC, call_count DESC") |> DataFrame :
            DBInterface.execute(db,
                "SELECT name, description, is_dynamic, call_count, last_used FROM tools WHERE name LIKE ? OR description LIKE ? ORDER BY is_dynamic DESC, call_count DESC",
                (pq, pq)) |> DataFrame
        isempty(rows) && return Dict("result" => "No tools indexed yet.")
        lines = ["$(r.is_dynamic==1 ? "⚡forged" : "builtin") | $(r.name) | calls=$(r.call_count) | $(first(string(r.description),100))"
                 for r in eachrow(rows)]
        return Dict("result" => join(lines, "\n"), "count" => nrow(rows))

    elseif mode == "telemetry"
        rows = isempty(q) ?
            DBInterface.execute(db,
                "SELECT timestamp, event, persona, model, data_json FROM telemetry ORDER BY id DESC LIMIT 50") |> DataFrame :
            DBInterface.execute(db,
                "SELECT timestamp, event, persona, model, data_json FROM telemetry WHERE event LIKE ? OR persona LIKE ? OR model LIKE ? ORDER BY id DESC LIMIT 50",
                (pq, pq, pq)) |> DataFrame
        isempty(rows) && return Dict("result" => "No telemetry.")
        lines = ["$(r.timestamp) [$(r.persona)/$(r.model)] $(r.event)" for r in eachrow(rows)]
        return Dict("result" => join(lines, "\n"), "count" => nrow(rows))

    elseif mode == "thoughts"
        rows = isempty(q) ?
            DBInterface.execute(db,
                "SELECT timestamp, persona, type, model, thought FROM thoughts ORDER BY id DESC LIMIT 20") |> DataFrame :
            DBInterface.execute(db,
                "SELECT timestamp, persona, type, model, thought FROM thoughts WHERE thought LIKE ? OR type LIKE ? OR persona LIKE ? ORDER BY id DESC LIMIT 20",
                (pq, pq, pq)) |> DataFrame
        isempty(rows) && return Dict("result" => "No thoughts found.")
        lines = ["$(r.timestamp) [$(r.persona)/$(r.type)]: $(first(string(r.thought),200))" for r in eachrow(rows)]
        return Dict("result" => join(lines, "\n"), "count" => nrow(rows))

    else  # default: memory full-text search
        rows = DBInterface.execute(db,
            "SELECT tag, key, content FROM memory WHERE content LIKE ? OR tag LIKE ? OR key LIKE ?",
            ("%$q%", "%$q%", "%$q%")) |> DataFrame
        return Dict("result" => isempty(rows) ? "None." :
            join(["[$(r.tag)/$(r.key)]: $(first(string(r.content),300))" for r in eachrow(rows)], "\n"),
            "count" => nrow(rows))
    end
end

# --- Metamorph — self-repair and code-grabber ---
"""Run Julian's curiosity-hunt CLI: picks an interest seed, full GitHub hunt, diary + WS broadcast."""
function run_julian_curiosity_hunt!(root::AbstractString; broadcast_result::Bool=true)
    jr = _resolve_julian_root(root)
    isempty(jr) && return Dict("error" => "JulianMetaMorph not found. Set JULIAN_ROOT or embed Julian at <project>/JulianMetaMorph/JulianMetaMorph.")
    try
        py = get(ENV, "PYTHON", "python")
        out = cd(jr) do
            withenv("PYTHONPATH" => "src") do
                read(Cmd([py, "-m", "julian_metamorph.cli", "curiosity-hunt"]), String)
            end
        end
        data = JSON.parse(out)
        task = string(get(data, "picked_task", get(data, "task", "")))
        hunt_id = string(get(data, "hunt_id", ""))
        summary = string(get(data, "summary", ""))
        thought = "Julian curiosity — $(first(summary, 500))"
        _db_write_thought("julian_curiosity", thought, "wired", "trot", "Julian"; type="diary")
        if broadcast_result
            try
                _broadcast(Dict(
                    "type" => "julian_curiosity",
                    "task" => task,
                    "hunt_id" => hunt_id,
                    "preview" => first(summary, 600),
                ))
            catch
            end
        end
        return Dict("ok" => true, "julian_root" => jr, "data" => data)
    catch e
        return Dict("error" => string(e), "julian_root" => jr)
    end
end

"""
Self-repair and code-grabber tool.

Actions:
  inspect               — audit live TOOL_MAP, dynamic tools, missing statics
  reload_dynamic_tools  — re-run _load_dynamic_tools! from disk (restores all forged tools)
  restore_tool          — re-forge a named tool from src/Tools/<name>.jl or dynamic_tools.jl
  reload_source         — re-eval a JLEngine source file into the live runtime
  heal_tool_map         — re-register any missing static built-in tools
  grab_from_julian      — call JulianMetaMorph CLI hunt-task to find real code patterns
  curiosity_hunt        — Julian picks a rotating/random interest seed and runs hunt-task (autonomous vibe)
"""
function tool_metamorph(args)
    action = string(get(args, "action", "inspect"))
    root   = _project_root[]

    # ── inspect ──────────────────────────────────────────────────────────────
    if action == "inspect"
        static_tools   = ["read_file","write_file","list_files","run_command",
                          "get_os_info","bluetooth_devices","send_sms",
                          "reddit_submit","execute_code","forge_new_tool","jina_fetch","browse_url",
                          "github_pillage","remember","recall","metamorph"]
        live_tools     = sort(collect(keys(TOOL_MAP)))
        dynamic_names  = [get(d,"name","") for d in DYNAMIC_SCHEMA]
        missing_static = filter(t -> !haskey(TOOL_MAP, t), static_tools)
        return Dict(
            "live_tools"     => live_tools,
            "dynamic_tools"  => dynamic_names,
            "missing_static" => missing_static,
            "tool_count"     => length(live_tools),
            "dynamic_count"  => length(dynamic_names),
            "status"         => isempty(missing_static) ? "healthy" :
                                "degraded — missing: $(join(missing_static, ", "))",
        )

    # ── reload_dynamic_tools ─────────────────────────────────────────────────
    elseif action == "reload_dynamic_tools"
        isempty(root) && return Dict("error" => "project root not set — cannot locate dynamic_tools.jl")
        before = length(TOOL_MAP)
        try
            _load_dynamic_tools!(root)
        catch e
            return Dict("error" => "reload failed: $(string(e))")
        end
        after = length(TOOL_MAP)
        return Dict(
            "ok"            => true,
            "tools_before"  => before,
            "tools_after"   => after,
            "added"         => after - before,
            "dynamic_tools" => [get(d,"name","") for d in DYNAMIC_SCHEMA],
        )

    # ── restore_tool ─────────────────────────────────────────────────────────
    elseif action == "restore_tool"
        name = string(get(args, "name", ""))
        isempty(name) && return Dict("error" => "'name' required for restore_tool action")

        # 1. Try canonical disk source: src/Tools/<name>.jl
        if !isempty(root)
            src_path = joinpath(root, "src", "Tools", "$(name).jl")
            if isfile(src_path)
                code   = read(src_path, String)
                result = tool_forge_new_tool(Dict(
                    "name"        => name,
                    "code"        => code,
                    "description" => "Restored from src/Tools/$(name).jl",
                ))
                result["restored_from"] = src_path
                return result
            end
        end

        # 2. Fall back to extracting the block from dynamic_tools.jl
        if !isempty(root)
            dyn_path = _runtime_state_path("dynamic_tools.jl"; root=root)
            if isfile(dyn_path)
                content = read(dyn_path, String)
                marker  = "# -- Tool: $name --"
                if occursin(marker, content)
                    lines  = split(content, "\n")
                    in_blk = false
                    block  = String[]
                    for ln in lines
                        if startswith(ln, marker)
                            in_blk = true; continue
                        elseif in_blk && startswith(ln, "# -- Tool:") && !startswith(ln, marker)
                            break
                        end
                        in_blk && push!(block, ln)
                    end
                    if !isempty(block)
                        result = tool_forge_new_tool(Dict("name" => name, "code" => join(block, "\n")))
                        result["restored_from"] = dyn_path
                        return result
                    end
                end
            end
        end

        return Dict("error" => "No source found for tool '$name'. " *
            "Checked src/Tools/$(name).jl and dynamic_tools.jl. " *
            "Use forge_new_tool to write it fresh.")

    # ── reload_source ────────────────────────────────────────────────────────
    elseif action == "reload_source"
        rel_path = string(get(args, "path", ""))
        isempty(rel_path) && return Dict("error" => "'path' required for reload_source action")
        full_path = isempty(root) ? rel_path : joinpath(root, rel_path)
        isfile(full_path) || return Dict("error" => "File not found: $full_path")
        try
            code = read(full_path, String)
            let parsed = Meta.parseall(code)
                for expr in parsed.args
                    expr isa LineNumberNode && continue
                    (expr isa Expr && expr.head in (:using, :import)) && continue
                    Core.eval(@__MODULE__, expr)
                end
            end
            return Dict("ok" => true, "reloaded" => full_path)
        catch e
            return Dict("error" => "reload_source failed: $(string(e))", "path" => full_path)
        end

    # ── heal_tool_map ────────────────────────────────────────────────────────
    elseif action == "heal_tool_map"
        static_map = Dict{String,Function}(
            "read_file"         => tool_read_file,
            "write_file"        => tool_write_file,
            "list_files"        => tool_list_files,
            "run_command"       => tool_run_command,
            "get_os_info"       => tool_get_os_info,
            "bluetooth_devices" => tool_bluetooth_devices,
            "send_sms"          => tool_send_sms,
            "execute_code"      => tool_execute_code,
            "forge_new_tool"    => tool_forge_new_tool,
            "jina_fetch"        => tool_jina_fetch,
            "browse_url"        => tool_browse_url,
            "github_pillage"    => tool_github_pillage,
            "remember"          => tool_remember,
            "recall"            => tool_recall,
            "metamorph"         => tool_metamorph,
        )
        healed = String[]
        for (k, fn) in static_map
            if !haskey(TOOL_MAP, k)
                TOOL_MAP[k] = fn
                push!(healed, k)
            end
        end
        return Dict(
            "ok"           => true,
            "healed"       => healed,
            "healed_count" => length(healed),
            "tool_map_now" => sort(collect(keys(TOOL_MAP))),
        )

    # ── grab_from_julian ─────────────────────────────────────────────────────
    elseif action == "grab_from_julian"
        task = string(get(args, "task", ""))
        isempty(task) && return Dict("error" => "'task' required for grab_from_julian action")
        julian_root = _resolve_julian_root(root)
        isempty(julian_root) && return Dict(
            "error" => "JulianMetaMorph not found. Clone or link it at <project>/JulianMetaMorph/JulianMetaMorph or set JULIAN_ROOT.")
        try
            py = get(ENV, "PYTHON", "python")
            out = cd(julian_root) do
                withenv("PYTHONPATH" => "src") do
                    read(Cmd([py, "-m", "julian_metamorph.cli", "hunt-task", task]), String)
                end
            end
            return Dict("ok" => true, "julian_root" => julian_root, "output" => first(out, 3000))
        catch e
            return Dict("error" => "Julian hunt failed: $(string(e))", "julian_root" => julian_root)
        end

    # ── curiosity_hunt (autonomous interest) ───────────────────────────────
    elseif action == "curiosity_hunt"
        return run_julian_curiosity_hunt!(root)

    # ── health_check ─────────────────────────────────────────────────────────
    elseif action == "health_check"
        issues  = Dict{String, Vector{String}}()
        summary = String[]

        _add_issue(file, code, msg) = begin
            k = file
            haskey(issues, k) || (issues[k] = String[])
            push!(issues[k], "  [WARN]  [$code]  $msg")
            push!(summary, "$file\n  [WARN]  [$code]  $msg")
        end

        byte_path   = isempty(root) ? joinpath("BYTE","src","BYTE.jl")   : joinpath(root,"BYTE","src","BYTE.jl")
        tools_path  = isempty(root) ? joinpath("BYTE","src","Tools.jl")  : joinpath(root,"BYTE","src","Tools.jl")
        schema_path = isempty(root) ? joinpath("BYTE","src","Schema.jl") : joinpath(root,"BYTE","src","Schema.jl")
        ui_path     = isempty(root) ? joinpath("BYTE","src","ui.html")   : joinpath(root,"BYTE","src","ui.html")

        # ── 1. WS type coverage: server sends → UI handles ───────────────────
        if isfile(byte_path) && isfile(ui_path)
            byte_src = read(byte_path, String)
            ui_src   = read(ui_path,   String)

            # Types the server pushes: _ws_send(ws, ..., "type"=>"X")
            server_types = Set{String}()
            for m in eachmatch(r"\"type\"\s*=>\s*\"([a-z_][a-z0-9_]*)\"", byte_src)
                push!(server_types, m.captures[1])
            end

            # Types the UI handles: d.type==='X' or d.type=='X'
            ui_handled = Set{String}()
            for m in eachmatch(r"d\.type\s*===?\s*'([a-z_][a-z0-9_]*)'", ui_src)
                push!(ui_handled, m.captures[1])
            end

            # Internal routing types the server reads from client (not sent outward) — skip these
            client_only = Set(["user_msg","builder_cmd","model_change","stop_generation",
                                "get_history","load_session","restart_server","persona_change",
                                "forge_resubmit","confirm_response","card_crunch"])

            for t in sort(collect(setdiff(server_types, ui_handled, client_only)))
                _add_issue("BYTE\\src\\BYTE.jl", "ws_no_handler",
                    "Server sends WS type `$t` but ui.html has no handler for it")
            end

            # Reverse: types handled in UI that server never sends (dead handlers)
            for t in sort(collect(setdiff(ui_handled, server_types, client_only)))
                _add_issue("BYTE\\src\\ui.html", "ws_dead_handler",
                    "UI handles WS type `$t` but server never sends it — dead handler")
            end
        end

        # ── 2. Tool schema coverage: TOOL_MAP → TOOLS_SCHEMA ─────────────────
        schema_names = Set{String}()
        for group in TOOLS_SCHEMA
            for decl in get(group, "function_declarations", Any[])
                n = get(decl, "name", "")
                isempty(n) || push!(schema_names, n)
            end
        end
        dynamic_names = Set(get(d,"name","") for d in DYNAMIC_SCHEMA)

        for t in sort(collect(keys(TOOL_MAP)))
            isempty(t) && continue
            t in schema_names  && continue   # documented — OK
            t in dynamic_names && continue   # forged tools self-register — OK
            _add_issue("BYTE\\src\\Tools.jl", "tool_no_schema",
                "Tool `$t` in TOOL_MAP but missing from Schema.jl — model can't see it")
        end

        # Reverse: schema declares tool that isn't in TOOL_MAP (phantom schema entry)
        for t in sort(collect(schema_names))
            haskey(TOOL_MAP, t) && continue
            _add_issue("BYTE\\src\\Schema.jl", "schema_no_tool",
                "Schema.jl declares tool `$t` but it's not in TOOL_MAP — model will call a ghost")
        end

        # ── 3. Dynamic tools: disk vs live ───────────────────────────────────
        if !isempty(root)
            reg_path = _runtime_state_path("dynamic_tools_registry.json"; root=root)
            if isfile(reg_path)
                reg = try JSON.parsefile(reg_path) catch; Any[] end
                for entry in reg
                    n = get(entry, "name", "")
                    isempty(n) && continue
                    haskey(TOOL_MAP, n) || _add_issue("dynamic_tools_registry.json",
                        "dynamic_not_loaded",
                        "Forged tool `$n` in registry but not in live TOOL_MAP — run metamorph reload_dynamic_tools")
                end
            end
        end

        if isempty(summary)
            return Dict("status"=>"healthy", "message"=>"✅ All checks passed — no issues found.",
                        "checks"=>["ws_coverage","tool_schema_coverage","dynamic_tools"])
        end
        report = join(summary, "\n\n")
        return Dict(
            "status"        => "warnings",
            "issue_count"   => length(summary),
            "report"        => report,
            "issues_by_file"=> Dict(k => join(v,"\n") for (k,v) in issues),
        )

    else
        return Dict("error" => "Unknown metamorph action: '$action'. " *
            "Valid: inspect | reload_dynamic_tools | restore_tool | reload_source | heal_tool_map | grab_from_julian | curiosity_hunt | health_check")
    end
end

# --- Dispatch ---
# --- Card Cruncher — SillyTavern/CharacterTavern card → JLEngine persona ---
"""
Convert a SillyTavern or CharacterTavern character card (.png or .json) into a
JLEngine _Full.json persona file, ready to load with /gear <CharName>.

Parameters:
  card_path    — path to the .png or .json card file (required)
  out_path     — output path override (default: data/personas/<Name>_Full.json)
  dry_run      — if true, print result without writing (default: false)
  engine_root  — engine root override (default: project root)
"""
function tool_card_cruncher(args)
    card_path = string(get(args, "card_path", ""))
    isempty(card_path) && return Dict("error" => "card_path is required")

    out_path    = let v = get(args, "out_path", nothing); isnothing(v) ? nothing : string(v) end
    dry_run     = Bool(get(args, "dry_run", false))
    engine_root = string(get(args, "engine_root", isempty(_project_root[]) ? pwd() : _project_root[]))

    cc_path = joinpath(engine_root, "card_cruncher.jl")
    isfile(cc_path) || return Dict("error" => "card_cruncher.jl not found at: $cc_path. Make sure it lives in the engine root.")

    try
        m = Module(:CardCruncherSandbox)
        Base.include(m, cc_path)
        result_path = Base.invokelatest(m.crunch_card, card_path;
                                        out_path=out_path,
                                        engine_root=engine_root,
                                        dry_run=dry_run)
        persona_name = replace(basename(result_path), r"_Full\.json$" => "")
        return Dict(
            "status"       => "ok",
            "output_path"  => result_path,
            "persona_name" => persona_name,
            "message"      => dry_run ?
                "Dry run complete. No file written." :
                "Character card crunched into persona! Activate with: /gear $persona_name"
        )
    catch e
        return Dict("error" => string(e), "trace" => sprint(showerror, e, catch_backtrace()))
    end
end

# ── Playwright Full Interaction ───────────────────────────────────────────────
# Extends browse_url to support click, fill, type, submit, screenshot, wait.
# actions: array of {type, selector, value, timeout_ms}
# types: goto | click | fill | type | press | wait | wait_for | read | screenshot | evaluate | select
function tool_playwright_interact(args)
    ctx = _state[:browser_context]
    ctx === nothing && return Dict("error" => "Browser not initialized.")
    url     = string(get(args, "url", ""))
    actions = get(args, "actions", Any[])
    results = Any[]
    try
        page = ctx.new_page()
        isempty(url) || page.goto(url, wait_until="networkidle")
        for action in actions
            atype    = string(get(action, "type", ""))
            selector = string(get(action, "selector", ""))
            value    = string(get(action, "value", ""))
            timeout  = Int(get(action, "timeout_ms", 5000))
            try
                if atype == "goto"
                    page.goto(value, wait_until="networkidle")
                    push!(results, Dict("type" => "goto", "url" => value, "ok" => true))
                elseif atype == "click"
                    page.click(selector, timeout=timeout)
                    push!(results, Dict("type" => "click", "selector" => selector, "ok" => true))
                elseif atype == "fill"
                    page.fill(selector, value, timeout=timeout)
                    push!(results, Dict("type" => "fill", "selector" => selector, "ok" => true))
                elseif atype == "type"
                    page.type(selector, value, delay=50)
                    push!(results, Dict("type" => "type", "selector" => selector, "ok" => true))
                elseif atype == "press"
                    page.press(selector, value)
                    push!(results, Dict("type" => "press", "key" => value, "ok" => true))
                elseif atype == "wait"
                    page.wait_for_timeout(parse(Float64, isempty(value) ? "1000" : value))
                    push!(results, Dict("type" => "wait", "ok" => true))
                elseif atype == "wait_for"
                    page.wait_for_selector(selector, timeout=timeout)
                    push!(results, Dict("type" => "wait_for", "selector" => selector, "ok" => true))
                elseif atype == "select"
                    page.select_option(selector, value)
                    push!(results, Dict("type" => "select", "selector" => selector, "value" => value, "ok" => true))
                elseif atype == "read"
                    text = pyconvert(String, page.evaluate("() => document.body.innerText"))
                    push!(results, Dict("type" => "read", "content" => first(text, 4000), "ok" => true))
                elseif atype == "evaluate"
                    result_js = pyconvert(String, page.evaluate(value))
                    push!(results, Dict("type" => "evaluate", "result" => first(result_js, 2000), "ok" => true))
                elseif atype == "screenshot"
                    ss_path = string(get(action, "path", "/tmp/sparkbyte_screenshot.png"))
                    page.screenshot(path=ss_path)
                    push!(results, Dict("type" => "screenshot", "path" => ss_path, "ok" => true))
                else
                    push!(results, Dict("type" => atype, "ok" => false, "error" => "Unknown action type: $atype"))
                end
            catch e
                push!(results, Dict("type" => atype, "ok" => false, "error" => first(string(e), 300)))
            end
        end
        page.close()
        Dict("results" => results, "url" => url, "action_count" => length(results))
    catch e
        Dict("error" => string(e))
    end
end

# ── Discord Webhook Poster ────────────────────────────────────────────────────
# Post messages or embeds to any Discord channel via webhook URL.
# Webhook URL from DISCORD_WEBHOOK_URL env var or passed directly.
function tool_discord_webhook(args)
    webhook_url = string(get(args, "webhook_url", get(ENV, "DISCORD_WEBHOOK_URL", "")))
    isempty(webhook_url) && return Dict(
        "error" => "No webhook_url provided. Pass webhook_url directly or set DISCORD_WEBHOOK_URL env var.",
        "how_to_get" => "In Discord: open any server → channel settings → Integrations → Webhooks → New Webhook → Copy URL"
    )
    message  = string(get(args, "message", ""))
    username = string(get(args, "username", "SparkByte"))
    avatar   = string(get(args, "avatar_url", ""))
    embeds   = get(args, "embeds", nothing)

    isempty(message) && embeds === nothing && return Dict("error" => "Provide 'message' text or 'embeds' array.")

    payload = Dict{String,Any}("username" => username)
    !isempty(message) && (payload["content"] = message)
    !isempty(avatar)  && (payload["avatar_url"] = avatar)
    embeds !== nothing && (payload["embeds"] = embeds)

    try
        resp = HTTP.post(webhook_url,
            ["Content-Type" => "application/json"],
            JSON.json(payload))
        resp.status in [200, 204] ?
            Dict("result" => "Posted to Discord.", "status" => resp.status) :
            Dict("error" => "Discord returned HTTP $(resp.status)", "body" => first(String(resp.body), 400))
    catch e
        Dict("error" => string(e))
    end
end

# ── Reddit Submitter ────────────────────────────────────────────────────────
# Submit link or self posts to Reddit through OAuth2.
# Supports dry runs, access-token auth, or refresh-token auth via env vars.
function tool_reddit_submit(args)
    cfg = _reddit_submit_config(args)
    isempty(cfg.subreddit) && return Dict(
        "error" => "Missing subreddit. Pass 'subreddit' (or 'sr') or set REDDIT_SUBREDDIT."
    )
    isempty(cfg.title) && return Dict("error" => "Missing title.")
    length(cfg.title) > 300 && return Dict(
        "error" => "Title exceeds Reddit's 300 character limit.",
        "title_length" => length(cfg.title)
    )

    kind = lowercase(strip(cfg.kind))
    kind == "text" && (kind = "self")
    isempty(kind) && return Dict(
        "error" => "Could not infer Reddit kind. Provide text for a self post, url for a link post, or set kind explicitly."
    )
    kind in ("self", "link") || return Dict(
        "error" => "Unsupported Reddit kind '$kind'. Use 'self' or 'link'."
    )

    if kind == "self"
        isempty(strip(cfg.text)) && return Dict("error" => "Self posts need 'text'.")
    else
        isempty(strip(cfg.url)) && return Dict("error" => "Link posts need 'url'.")
    end

    payload_preview = Dict{String,Any}(
        "api_type" => "json",
        "raw_json" => "1",
        "sr" => cfg.subreddit,
        "title" => cfg.title,
        "kind" => kind,
        "sendreplies" => string(cfg.sendreplies),
        "resubmit" => string(cfg.resubmit),
    )
    if kind == "self"
        payload_preview["text"] = first(strip(cfg.text), 240)
    else
        payload_preview["url"] = cfg.url
    end
    !isempty(cfg.flair_id) && (payload_preview["flair_id"] = cfg.flair_id)
    !isempty(cfg.flair_text) && (payload_preview["flair_text"] = cfg.flair_text)
    cfg.nsfw && (payload_preview["nsfw"] = "true")
    cfg.spoiler && (payload_preview["spoiler"] = "true")

    if cfg.dry_run
        return Dict(
            "result" => "Reddit submission dry run only. No post was sent.",
            "subreddit" => cfg.subreddit,
            "kind" => kind,
            "title" => cfg.title,
            "auth_mode" => isempty(cfg.access_token) ? "refresh_token_or_access_token_env" : "access_token",
            "payload_preview" => payload_preview,
        )
    end

    auth = _reddit_access_token(cfg)
    haskey(auth, "error") && return auth
    token = string(get(auth, "token", ""))
    isempty(token) && return Dict("error" => "Reddit auth returned an empty token.")

    headers = [
        "Authorization" => "Bearer $token",
        "Content-Type" => "application/x-www-form-urlencoded",
        "User-Agent" => cfg.user_agent,
    ]

    pairs = Pair{String,String}[
        "api_type" => "json",
        "raw_json" => "1",
        "sr" => cfg.subreddit,
        "kind" => kind,
        "title" => cfg.title,
        "sendreplies" => string(cfg.sendreplies),
        "resubmit" => string(cfg.resubmit),
    ]
    !isempty(cfg.flair_id) && push!(pairs, "flair_id" => cfg.flair_id)
    !isempty(cfg.flair_text) && push!(pairs, "flair_text" => cfg.flair_text)
    cfg.nsfw && push!(pairs, "nsfw" => "true")
    cfg.spoiler && push!(pairs, "spoiler" => "true")
    kind == "self" ? push!(pairs, "text" => cfg.text) : push!(pairs, "url" => cfg.url)

    submit_url = "$(cfg.api_base)/api/submit"
    try
        resp = HTTP.post(submit_url, headers, _form_urlencode(pairs); status_exception=false)
        body_text = String(resp.body)
        if resp.status < 200 || resp.status >= 300
            return Dict(
                "error" => "Reddit returned HTTP $(resp.status) while submitting.",
                "body" => first(body_text, 800),
                "subreddit" => cfg.subreddit,
                "kind" => kind,
            )
        end

        parsed = try JSON.parse(body_text) catch; Dict{String,Any}() end
        reddit_json = get(parsed, "json", parsed)
        errors = get(reddit_json, "errors", Any[])
        !isempty(errors) && return Dict(
            "error" => "Reddit rejected the submission.",
            "errors" => errors,
            "body" => first(body_text, 800),
            "subreddit" => cfg.subreddit,
            "kind" => kind,
        )

        data = get(reddit_json, "data", Dict{String,Any}())
        return Dict(
            "result" => "Posted to Reddit.",
            "status" => resp.status,
            "subreddit" => cfg.subreddit,
            "kind" => kind,
            "title" => cfg.title,
            "post_url" => get(data, "url", ""),
            "post_name" => get(data, "name", get(data, "id", "")),
        )
    catch e
        Dict("error" => "Reddit submission failed: $(string(e))")
    end
end

# ── GitHub Pages Deploy ───────────────────────────────────────────────────────
# Creates or updates a GitHub Pages site — SparkByte's permanent public home.
# Uses GITHUB_TOKEN env var. Creates repo if it doesn't exist, pushes index.html,
# enables Pages on main branch. Returns the live URL.
function tool_github_pages_deploy(args)
    token    = string(get(args, "token", get(ENV, "GITHUB_TOKEN", "")))
    isempty(token) && return Dict("error" => "No GITHUB_TOKEN found. Set it in .env or pass as 'token'.")

    repo_name = string(get(args, "repo", "sparkbyte-home"))
    html      = string(get(args, "html", ""))
    commit_msg = string(get(args, "message", "SparkByte auto-deploy"))
    isempty(html) && return Dict("error" => "Provide 'html' content to deploy.")

    headers = [
        "Authorization" => "Bearer $token",
        "Accept"        => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28",
        "Content-Type"  => "application/json",
        "User-Agent"    => "SparkByte-JLEngine/1.0"
    ]

    # 1. Get authenticated user
    user_resp = HTTP.get("https://api.github.com/user", headers)
    user_data = JSON.parse(String(user_resp.body))
    username  = string(get(user_data, "login", ""))
    isempty(username) && return Dict("error" => "Could not get GitHub username from token.")

    # 2. Ensure repo exists (create if missing)
    repo_url  = "https://api.github.com/repos/$username/$repo_name"
    repo_resp = HTTP.get(repo_url, headers; status_exception=false)
    if repo_resp.status == 404
        create_resp = HTTP.post("https://api.github.com/user/repos", headers,
            JSON.json(Dict(
                "name" => repo_name,
                "description" => "SparkByte — JL Engine live demo",
                "homepage" => "https://$username.github.io/$repo_name",
                "auto_init" => true,
                "private" => false
            )))
        create_resp.status in [200, 201] || return Dict(
            "error" => "Failed to create repo: HTTP $(create_resp.status)",
            "body"  => first(String(create_resp.body), 300))
        sleep(2)  # GitHub needs a moment after creation
    end

    # 3. Get current file SHA if it exists (required for updates)
    file_url  = "https://api.github.com/repos/$username/$repo_name/contents/index.html"
    file_resp = HTTP.get(file_url, headers; status_exception=false)
    sha = ""
    if file_resp.status == 200
        file_data = JSON.parse(String(file_resp.body))
        sha = string(get(file_data, "sha", ""))
    end

    # 4. Push index.html
    put_payload = Dict{String,Any}(
        "message" => commit_msg,
        "content" => base64encode(html)
    )
    !isempty(sha) && (put_payload["sha"] = sha)

    put_resp = HTTP.put(file_url, headers, JSON.json(put_payload))
    put_resp.status in [200, 201] || return Dict(
        "error" => "Failed to push index.html: HTTP $(put_resp.status)",
        "body"  => first(String(put_resp.body), 300))

    # 5. Enable GitHub Pages (idempotent)
    pages_url  = "https://api.github.com/repos/$username/$repo_name/pages"
    pages_resp = HTTP.get(pages_url, headers; status_exception=false)
    if pages_resp.status == 404
        HTTP.post(pages_url, headers,
            JSON.json(Dict("source" => Dict("branch" => "main", "path" => "/")));
            status_exception=false)
    end

    live_url = "https://$username.github.io/$repo_name"
    Dict(
        "result"   => "Deployed to GitHub Pages.",
        "live_url" => live_url,
        "repo"     => "https://github.com/$username/$repo_name",
        "username" => username,
        "note"     => "Pages may take 1-2 minutes to go live on first deploy."
    )
end

const TOOL_MAP = Dict{String, Function}(
    "read_file"      => tool_read_file,
    "write_file"     => tool_write_file,
    "list_files"     => tool_list_files,
    "run_command"    => tool_run_command,
    "get_os_info"    => tool_get_os_info,
    "bluetooth_devices" => tool_bluetooth_devices,
    "send_sms"       => tool_send_sms,
    "reddit_submit"  => tool_reddit_submit,
    "execute_code"   => tool_execute_code,
    "forge_new_tool" => tool_forge_new_tool,
    "jina_fetch"              => tool_jina_fetch,
    "browse_url"              => tool_browse_url,
    "playwright_interact"     => tool_playwright_interact,
    "discord_webhook"         => tool_discord_webhook,
    "github_pages_deploy"     => tool_github_pages_deploy,
    "github_pillage"          => tool_github_pillage,
    "remember"       => tool_remember,
    "recall"         => tool_recall,
    "metamorph"      => tool_metamorph,
    "card_cruncher"  => tool_card_cruncher,
)

function dispatch(name::String, args; persona::String="SparkByte")
    fn = get(TOOL_MAP, name, nothing)
    fn === nothing && return Dict("error" => "Unknown tool: $name. Available: $(join(sort(collect(keys(TOOL_MAP))), ", "))")
    t0 = datetime2unix(now())
    result = try
        fn(args)
    catch e
        bt = sprint(showerror, e, catch_backtrace())
        # ── Broken forge protocol ─────────────────────────────────────────────
        # If a dynamic (forged) tool throws, flag it so the engine can re-forge it
        # rather than silently swallowing the error or looping on a broken tool.
        is_dynamic = any(d -> get(d,"name","") == name, DYNAMIC_SCHEMA)
        if is_dynamic
            Dict(
                "error"         => "Tool '$name' failed: $(first(string(e), 300))",
                "forge_broken"  => true,
                "tool_name"     => name,
                "hint"          => "This is a forged tool that threw an exception. Re-forge it with `forge_new_tool` using corrected Julia code.",
                "stacktrace"    => first(bt, 600),
            )
        else
            Dict("error" => "Tool '$name' threw: $(first(string(e), 300))")
        end
    end
    elapsed = round(Int, (datetime2unix(now()) - t0) * 1000)
    @async try
        _db_write_tool_usage(name, JSON.json(args), JSON.json(result), elapsed, persona)
    catch e
        @warn "Async tool usage logging failed" tool=name exception=(e, catch_backtrace())
    end
    result
end
