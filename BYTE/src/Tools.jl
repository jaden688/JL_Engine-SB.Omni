haskey(ENV, "JULIA_CONDAPKG_BACKEND") || (ENV["JULIA_CONDAPKG_BACKEND"] = "Null")
haskey(ENV, "JULIA_PYTHONCALL_EXE") || (ENV["JULIA_PYTHONCALL_EXE"] = "python")

using PythonCall, SQLite, DataFrames, Dates, JSON, HTTP, Base64

# Lazy-initialized singletons — set by BYTE.init()
const _state = Dict{Symbol, Any}(
    :db => nothing,
    :browser_context => nothing,
)

# Mutable live registry for dynamically forged tools
const DYNAMIC_SCHEMA       = Dict{String,Any}[]
const _project_root        = Ref{String}("")
const _session_event_count = Ref{Int}(0)

# ── Forge event hooks — registered by BYTE on init for live dashboard broadcast ──
# Each entry is fn(name::String, code::String, description::String) -> nothing
const _FORGE_HOOKS = Function[]

# ── Live Memory Listener ──────────────────────────────────────────────────────

function _db_write_thought(context::String, thought::String, mood::String, gait::String, persona::String="SparkByte"; type::String="diary", model::String="")
    db = _state[:db]
    db === nothing && return
    try
        SQLite.execute(db,
            "INSERT INTO thoughts (timestamp, persona, context, thought, mood, gait, type, model) VALUES (?,?,?,?,?,?,?,?)",
            (string(now()), persona, first(context, 120), first(thought, 400), mood, gait, type, model))
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
        SQLite.execute(db,
            "INSERT INTO thoughts (timestamp, persona, context, thought, mood, gait, type, model) VALUES (?,?,?,?,?,?,?,?)",
            (string(now()), persona, first(context, 120), first(reasoning, 2000), "reasoning", "auto", "reasoning", model))
        _session_event_count[] += 1
    catch e
        @warn "Reasoning write failed" exception=(e, catch_backtrace())
    end
end

function _db_write_tool_usage(name::String, args_json::String, result_json::String, elapsed_ms::Int, persona::String)
    db = _state[:db]
    db === nothing && return
    try
        SQLite.execute(db,
            "INSERT INTO tool_usage_log (timestamp, tool_name, args_json, result_json, duration_ms, persona, session_id) VALUES (?,?,?,?,?,?,?)",
            (string(now()), name, first(args_json, 500), first(result_json, 500), elapsed_ms, persona, isdefined(@__MODULE__, :_session_id) ? string(getfield(@__MODULE__, :_session_id)) : "unknown"))
        SQLite.execute(db, "UPDATE tools SET call_count = call_count + 1, last_used = ? WHERE name = ?", (string(now()), name))
        _session_event_count[] += 1
    catch e
        @warn "Tool usage write failed" exception=(e, catch_backtrace())
    end
end

function _db_write_web_cache(url::String, content::String)
    db = _state[:db]
    db === nothing && return
    try
        existing = DBInterface.execute(db, "SELECT id FROM web_cache WHERE url = ?", (url,)) |> DataFrame
        summary = first(content, 300)
        if isempty(existing)
            SQLite.execute(db,
                "INSERT INTO web_cache (url, fetched_at, content, summary, tags) VALUES (?,?,?,?,?)",
                (url, string(now()), first(content, 5000), summary, "browsed"))
        else
            SQLite.execute(db,
                "UPDATE web_cache SET fetched_at=?, content=?, summary=? WHERE url=?",
                (string(now()), first(content, 5000), summary, url))
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
        SQLite.execute(db,
            "INSERT INTO sessions (session_id, started_at, os, julia_ver, events, notes) VALUES (?,?,?,?,?,?)",
            (session_id, string(now()), string(Sys.KERNEL), string(VERSION), 0, "Boot"))
    catch e
        @warn "Session start write failed" session_id=session_id exception=(e, catch_backtrace())
    end
end

function _db_end_session(session_id::String)
    db = _state[:db]
    db === nothing && return
    try
        SQLite.execute(db,
            "UPDATE sessions SET ended_at=?, events=? WHERE session_id=? AND ended_at IS NULL",
            (string(now()), _session_event_count[], session_id))
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

function _shell_command(command::String)
    if Sys.iswindows()
        return `powershell -NoProfile -NonInteractive -Command $command`
    end
    shell = Sys.which("bash")
    shell === nothing && (shell = Sys.which("sh"))
    shell === nothing && error("No shell found for run_command.")
    return `$shell -lc $command`
end

# --- Shell ---
function tool_run_command(args)
    try
        cmd_str = string(args["command"])
        out = read(_shell_command(cmd_str), String)
        Dict("result" => out)
    catch e
        Dict("error" => string(e))
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
        out = read(cmd, String)
        rm(tmp; force=true)
        Dict("stdout" => out)
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

        # ── Rule 1 is now NO DECEPTION — attempt is allowed, live test proves it ──
        # Phantom hardware check still applies (no faking microphone, camera, etc.)
        hw_violations = filter(v -> any(occursin(pat, code) for (pat, _) in _PHANTOM_CAPABILITIES),
                               [label for (pat, label) in _PHANTOM_CAPABILITIES if occursin(pat, code)])
        if !isempty(hw_violations)
            return Dict("error" => "FORGE REJECTED — hardware you cannot access: $(join(hw_violations, ", ")). " *
                "Do not fake hardware capabilities. Return a real error if the device isn't available.")
        end

        # 1. Eval code into BYTE module — live immediately
        # Iterate per-expression (same as _load_dynamic_tools!) so that top-level
        # `using` statements (packages already in scope) don't trigger world-age
        # recursion in Julia 1.12 when eval'd as a single :toplevel block.
        let parsed = Meta.parseall(code)
            for expr in parsed.args
                expr isa LineNumberNode && continue
                # Skip bare `using X` / `import X` — all allowed packages are
                # already loaded in the BYTE module scope.
                (expr isa Expr && expr.head in (:using, :import)) && continue
                Core.eval(@__MODULE__, expr)
            end
        end

        # 2. Verify expected function exists
        fn_sym = Symbol("tool_$name")
        if !isdefined(@__MODULE__, fn_sym)
            return Dict("error" => "Eval succeeded but `tool_$name(args)` not found. Code must define exactly that function name.")
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
function tool_browse_url(args)
    ctx = _state[:browser_context]
    ctx === nothing && return Dict("error" => "Browser not initialized.")
    try
        page = ctx.new_page()
        page.goto(string(args["url"]), wait_until="networkidle")
        text = pyconvert(String, page.evaluate("() => document.body.innerText"))
        page.close()
        @async try; _db_write_web_cache(string(args["url"]), text); catch e; @warn "Web cache write failed" exception=(e, catch_backtrace()); end
        Dict("content" => first(text, 5000))
    catch e Dict("error" => string(e)) end
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
"""
Self-repair and code-grabber tool.

Actions:
  inspect               — audit live TOOL_MAP, dynamic tools, missing statics
  reload_dynamic_tools  — re-run _load_dynamic_tools! from disk (restores all forged tools)
  restore_tool          — re-forge a named tool from src/Tools/<name>.jl or dynamic_tools.jl
  reload_source         — re-eval a JLEngine source file into the live runtime
  heal_tool_map         — re-register any missing static built-in tools
  grab_from_julian      — call JulianMetaMorph CLI hunt-task to find real code patterns
"""
function tool_metamorph(args::Dict)
    action = string(get(args, "action", "inspect"))
    root   = _project_root[]

    # ── inspect ──────────────────────────────────────────────────────────────
    if action == "inspect"
        static_tools   = ["read_file","write_file","list_files","run_command",
                          "get_os_info","bluetooth_devices","send_sms",
                          "execute_code","forge_new_tool","browse_url",
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
        julian_root = get(ENV, "JULIAN_ROOT",
            raw"C:\Users\J_lin\Desktop\JulianMetaMorph\JulianMetaMorph")
        isdir(julian_root) || return Dict(
            "error" => "Julian root not found: $julian_root. Set JULIAN_ROOT env var.")
        try
            cmd = _shell_command(
                "cd \"$julian_root\" && set PYTHONPATH=src && " *
                "python -m julian_metamorph.cli hunt-task \"$task\"")
            out = read(cmd, String)
            return Dict("ok" => true, "output" => first(out, 3000))
        catch e
            return Dict("error" => "Julian hunt failed: $(string(e))")
        end

    else
        return Dict("error" => "Unknown metamorph action: '$action'. " *
            "Valid: inspect | reload_dynamic_tools | restore_tool | reload_source | heal_tool_map | grab_from_julian")
    end
end

# --- Dispatch ---
const TOOL_MAP = Dict{String, Function}(
    "read_file"      => tool_read_file,
    "write_file"     => tool_write_file,
    "list_files"     => tool_list_files,
    "run_command"    => tool_run_command,
    "get_os_info"    => tool_get_os_info,
    "bluetooth_devices" => tool_bluetooth_devices,
    "send_sms"       => tool_send_sms,
    "execute_code"   => tool_execute_code,
    "forge_new_tool" => tool_forge_new_tool,
    "browse_url"     => tool_browse_url,
    "github_pillage" => tool_github_pillage,
    "remember"       => tool_remember,
    "recall"         => tool_recall,
    "metamorph"      => tool_metamorph,
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
