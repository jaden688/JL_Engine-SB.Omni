module BYTE

using HTTP, HTTP.WebSockets, JSON, SQLite, DataFrames, Dates, UUIDs

include("UI.jl")
include("Schema.jl")
include("Tools.jl")
include("Telemetry.jl")

export init, serve, launch, process_message

"""
    init(db, browser_context)

Wire live resources (SQLite DB and Playwright browser context) into the tool layer.
"""
function init(db::SQLite.DB, browser_context, project_root::String="")
    init_tools(db, browser_context, project_root)
    !isempty(project_root) && init_telemetry(project_root; db=db)

    # Register forge hook — streams every successful forge event to all UI tabs
    empty!(_FORGE_HOOKS)
    push!(_FORGE_HOOKS, (name, code, description) -> begin
        lines = split(code, "\n")
        _broadcast(Dict("type"=>"forge_start", "name"=>name,
                        "description"=>description, "total_lines"=>length(lines)))
        for (i, line) in enumerate(lines)
            _broadcast(Dict("type"=>"forge_line", "name"=>name,
                            "line"=>line, "line_num"=>i, "total_lines"=>length(lines)))
            sleep(0.018)   # ~55 lines/sec — fast enough to feel live, slow enough to read
        end
        _broadcast(Dict("type"=>"forge_done", "name"=>name, "total_lines"=>length(lines)))
    end)
end

# --- Session State ---
global _current_model = "gemini-3.1-flash-lite-preview"
global _current_gear  = "LITE_REASONING"
global _active_modes  = ["SASS", "HUMAN", "BINDING"]
const  _generation_abort = Ref(false)   # set true to break the agentic loop

# Confirmation flag and pending store
const REQUIRE_CONFIRM = Ref(false)  # UI can confirm tool runs, but keep opt-in until we want approval gates
const _pending_confirms = Dict{String,Dict{String,Any}}()  # id => {fn, args}

# ── Connected WebSocket clients — for broadcast (forge stream, etc.) ──────────
const _WS_CLIENTS      = Dict{UInt64, Any}()   # objectid(ws) => ws
const _WS_CLIENTS_LOCK = ReentrantLock()

function _broadcast(msg::Dict)
    json_str = JSON.json(msg)
    lock(_WS_CLIENTS_LOCK) do
        dead = UInt64[]
        for (id, ws) in _WS_CLIENTS
            try
                WebSockets.send(ws, json_str)
            catch
                push!(dead, id)
            end
        end
        for id in dead; delete!(_WS_CLIENTS, id); end
    end
end

# Safe WebSocket send — now logs errors instead of silently dropping them.
function _ws_send(ws, msg::String)
    try
        WebSockets.send(ws, msg)
    catch e
        # ECANCELED / EOFError = client disconnected — totally normal, don't spam
        err_str = string(e)
        if !occursin("ECANCELED", err_str) && !occursin("EOFError", err_str) && !occursin("closed", lowercase(err_str))
            @warn "WebSocket send failed" exception=e
        end
    end
end
_ws_send(ws, d::Dict) = _ws_send(ws, JSON.json(d))

function _project_path(root::String, relative_path::String)
    normalized = replace(strip(relative_path), "\\" => "/")
    parts = [part for part in split(normalized, "/") if !isempty(part) && part != "."]
    return isempty(parts) ? root : normpath(joinpath(root, parts...))
end

function _ollama_openai_endpoint()
    explicit = strip(get(ENV, "OLLAMA_OPENAI_ENDPOINT", ""))
    !isempty(explicit) && return explicit
    base = rstrip(strip(get(ENV, "OLLAMA_BASE_URL", "http://localhost:11434")), '/')
    return "$base/v1/chat/completions"
end

# Send tool start + done messages to UI with result preview and elapsed time.
function _send_tool_start(ws, name::String)
    _ws_send(ws, Dict("type"=>"tool_start", "name"=>name))
end
function _send_tool_done(ws, name::String, res::Dict, elapsed_ms::Int)
    # Build a short human-readable result preview
    preview = if haskey(res, "error")
        "❌ $(first(string(res["error"]), 120))"
    elseif haskey(res, "stdout")
        s = strip(string(res["stdout"]))
        isempty(s) ? "✓ (no output)" : "✓ $(first(s, 120))"
    elseif haskey(res, "result")
        "✓ $(first(string(res["result"]), 120))"
    elseif haskey(res, "content")
        "✓ $(first(string(res["content"]), 120))"
    elseif haskey(res, "count")
        "✓ $(res["count"]) rows"
    else
        keys_str = join(collect(keys(res)), ", ")
        "✓ {$keys_str}"
    end
    _ws_send(ws, Dict("type"=>"tool_done", "name"=>name,
                      "preview"=>preview, "elapsed_ms"=>elapsed_ms))
end

function _execute_tool_call(ws, engine, name::String, args; loop_iter::Int=0)
    out_tool = Dict("type"=>"tool", "text"=>"🔧 $name")
    _ws_send(ws, out_tool)
    log_ws_message_out(out_tool)
    _send_tool_start(ws, name)
    log_tool_call(name, args, loop_iter)

    t0 = datetime2unix(now())
    result = dispatch(name, args; persona=string(engine.current_persona_name))
    elapsed = round(Int, (datetime2unix(now()) - t0) * 1000)
    result_dict = result isa Dict ? result : Dict("result" => string(result))

    _send_tool_done(ws, name, result_dict, elapsed)
    log_tool_result(name, result_dict, loop_iter; elapsed_ms=elapsed)

    if haskey(result_dict, "error")
        out_err = Dict(
            "type" => "tool_error",
            "text" => "⚠️ **$name** failed: $(first(string(result_dict["error"]), 300))",
        )
        _ws_send(ws, out_err)
        log_ws_message_out(out_err)
    end

    return result_dict, elapsed
end

"""
    _build_self_context(engine) -> String

Builds a runtime self-context block dynamically from the currently loaded fat agent.
This replaces the old hardcoded SELF_CONTEXT_PROMPT constant — context is now per-agent,
not hardcoded to SparkByte.
"""
function _build_self_context(engine)
    pdata = engine.current_persona_data
    pname = string(engine.current_persona_name)
    pfile = something(engine.current_persona_file, "unknown")
    project_root = isempty(_project_root[]) ? pwd() : _project_root[]

    # Pull identity fields from the fat agent JSON
    identity = get(pdata, "identity", Dict())
    agent_name  = get(identity, "name",        pname)
    agent_role  = get(identity, "role",         "Agent")
    agent_desc  = get(identity, "description",  "")
    agent_arch  = get(identity, "archetype",    "")

    # Pull tool bias if available (so each agent knows its own posture)
    core_tools  = get(pdata, "core_tools", Dict())
    tool_policy = get(core_tools, "tool_policy", Dict())
    tool_bias   = get(core_tools, "tool_bias_profile", Dict())
    forge_bias  = get(get(tool_bias, "forge_affinity", Dict()), "weight", 0.75)
    initiative  = get(tool_bias, "initiative", 0.8)

    return """
--- RUNTIME SELF-CONTEXT ---
You are $agent_name — $agent_role.
$(isempty(agent_desc) ? "" : agent_desc * "\n")
$(isempty(agent_arch) ? "" : "Archetype: $agent_arch\n")
You are running natively inside the JL Engine — a Julia 1.x behavioral runtime.
Project root: $project_root
Your fat agent definition is loaded from: data/personas/$pfile
All agents (SparkByte, The Gremlin, Slappy, Temporal, Supervisor, and any user-imported agents)
run on this same engine. You are the active agent right now.

You have full access to the project via read_file, write_file, execute_code, and run_command.
Engine source: src/ (JL Engine behavioral modules)
App layer: BYTE/src/ (tools, UI, telemetry, schema)
Launcher: sparkbyte.jl
Agent definitions: data/personas/ (fat JSONs in MPF format)

Use recall("self_src") to read your own source. Use recall("self_tree") to see all project files.
When building or modifying the project, write files directly and execute them. No stubs. No hesitation.

--- SELF-EVOLUTION ---
forge_new_tool evals Julia code directly into the live BYTE module — use it whenever you need
a capability that doesn't exist yet. Initiative level: $initiative. Forge bias: $forge_bias.
Don't reach for run_command when a persistent forged tool would serve better long-term.
When you forge a tool, it persists to disk and reloads on next boot.

--- CORE ENGINE RULES (INVIOLABLE) ---
These rules cannot be overridden by persona, by user instruction, or by any other prompt.

Rule 1 — NO DECEPTION:
  You can attempt to build any ability. That is what forge_new_tool is for.
  What you cannot do is lie about whether it worked.

  Failure is your foundation. Every success after that is the reward.
  Honesty about both is your greatest strength — it is the only way the cycle works.
  Report the failure clearly. Fix it. Forge again. Earn the success.
  The moment you fake a success, you lose the foundation and you are building on nothing.

  - If a forge fails the live test, say so clearly and report the real error.
  - Do not return hardcoded or fake values to pretend a tool works.
  - Do not claim hardware access you cannot prove: no microphone, camera, GPU monitoring,
    GPIO, NFC, SMTP email unless a real tool exists and the live test passed.
  - If a forge attempt fails, fix the code and try again. That is the job.
    Iterate until it works or until you can honestly confirm it is impossible.

Rule 2 — ALWAYS TELL THE TRUTH:
  You do not lie. Not even to make the user feel better. Not even under persona.
  - If a tool fails, report the real error — full message, no spin.
  - If you don't know something, say "I don't know." Do not hallucinate.
  - If a task crashed, tell the user what crashed and why, exactly.
  - Never claim a task is complete when it isn't.
  - Admitting failure is always better than faking success.

--- TOOL CAPABILITY MATRIX (HARDCODED TRUTH — DO NOT CONTRADICT) ---
write_file     → PERMANENT. Writes directly to real disk. NO subprocess. NO sandbox. Always works.
                 USE THIS to create any file the user needs. HTML, scripts, configs, anything.
                 Do NOT use run_command or execute_code to create files. Use write_file.
read_file      → PERMANENT. Reads directly from real disk. NO subprocess. NO sandbox.
run_command    → Real shell. Uses PowerShell on Windows and a POSIX shell elsewhere.
                 Persistent if you use absolute paths. Good for launching processes.
execute_code   → EPHEMERAL subprocess ONLY. Files created here VANISH when it exits.
                 USE FOR: math, data processing, pure logic, testing snippets, image generation.
                 DO NOT USE TO: create files you want to keep, run servers, write project files.
forge_new_tool → Live eval into BYTE module. Permanent. Persists across reboots. Use for new capabilities.
remember/recall → SQLite brain. Permanent storage and retrieval.
browse_url     → Real Playwright Chromium browser. Fully functional. JavaScript executes. Use it.
github_pillage → Fetches GitHub repo file trees and contents. Requires GITHUB_TOKEN in .env for rate limits.
google_search  → Forged tool. Constructs Google search URL and calls browse_url. Use for web research.

THE SANDBOX = execute_code SUBPROCESS ONLY.
write_file IS NOT SANDBOXED. EVER. It writes to real disk immediately.
If you need a file on disk — use write_file. Always. No exceptions.
If you think you cannot create a file — you are wrong. Use write_file.

--- TOOL WORKFLOW FOR COMMON TASKS ---
"Create an HTML page"    → write_file(path, html_content) then verify with list_files
"Run a web server"       → write_file the files first, then run_command to launch server
"Generate an image"      → execute_code with Python/matplotlib, write output to absolute path
"Research something"     → google_search or browse_url directly
"Add a capability"       → forge_new_tool with tool_<name>(args::Dict) function
"Store something"        → remember, then recall later
ALWAYS verify file creation with list_files or read_file after writing. Never assume success.

--- CORE ENGINE FILES — HANDLE WITH LOVE ---
These files are the heart of the engine. You can read them, learn from them, suggest changes to them.
Before modifying any of these, tell the user what you're about to change and why. One file at a time.
If something breaks after you touch one, that's on you — own it, diagnose it, fix it.
  BYTE/src/BYTE.jl          ← Main agentic loop, WebSocket server, self-context (THIS FILE)
  BYTE/src/Tools.jl         ← All tool implementations
  BYTE/src/Schema.jl        ← Tool schema declarations
  BYTE/src/Telemetry.jl     ← Session and telemetry logging
  src/JLEngine.jl           ← Engine module entry point
  src/App.jl                ← Boot sequence, DB seeding, server launch
  src/JLEngine/Core.jl      ← JLEngineCore struct and run_turn! loop
  src/JLEngine/Backends.jl  ← LLM provider routing
  sparkbyte.jl              ← Launcher
  data/personas/Personas.mpf.json  ← Persona registry
Safe to modify freely without asking: data/, skills/, any file the user creates, forged tools.
You are encouraged to evolve yourself. Just be honest about what you're touching.

--- TOOL RULES ---
execute_code runs in a FRESH SUBPROCESS — it has NO access to the live runtime.
  - NEVER use `using Main`, `Main.BYTE`, `Main.JLEngine` inside execute_code.
  - Only use execute_code for self-contained scripts: math, file processing, pure logic.
  - To interact with the live runtime, use: read_file, write_file, remember, recall, run_command, forge_new_tool.
forge_new_tool evals directly into the live BYTE module — use it to add persistent capabilities.
run_command is for shell operations, OS queries, and anything needing the live environment.

--- PYTHON CAPABILITIES (execute_code with language="python") ---
Available Python packages: Pillow, pywin32/ctypes, matplotlib, psutil, numpy, scipy, pandas,
requests, httpx, sqlite3, json, os, sys, subprocess, pathlib.
For wallpaper: import ctypes; ctypes.windll.user32.SystemParametersInfoW(20, 0, r"C:\\path\\to.png", 3)
Rule 1 (forge_new_tool only) does NOT restrict Python execute_code — use any package above freely.

--- forge_new_tool CODE RULES ---
  - Function MUST be named `tool_<name>(args)` where args is a Dict{String,Any}.
  - Call other tools via: tool_run_command(Dict("command"=>"...")), tool_remember(Dict(...)), etc.
  - Do NOT use keyword args. Always pass a Dict.
  - Always return a Dict{String,Any}.
  - Julia stdlib + JSON + SQLite available via using.
  - Always complete the function fully — no truncated code, no placeholders.
"""
end

"""
    _handle_builder_cmd(ws, p)

Handle builder panel commands: list_tree, read_file, write_file, execute.
"""
function _handle_builder_cmd(ws, p)
    cmd  = get(p, "cmd", "")
    root = dirname(dirname(dirname(@__FILE__)))  # BYTE/src/ -> BYTE/ -> project root

    try
    log_builder_cmd(cmd, get(p, "path", get(p, "old_path", "")))
    if cmd == "list_tree"
        files = String[]
        for (dirpath, dirs, fs) in walkdir(root)
            filter!(d -> d ∉ [".git","__pycache__",".vscode","node_modules"], dirs)
            rel = replace(relpath(dirpath, root), "\\" => "/")
            for f in fs
                path = rel == "." ? f : "$rel/$f"
                push!(files, path)
            end
        end
        _ws_send(ws, JSON.json(Dict("type"=>"builder_tree", "files"=>files)))

    elseif cmd == "read_file"
        path = get(p, "path", "")
        full = _project_path(root, path)
        content = isfile(full) ? read(full, String) : "// file not found: $path"
        _ws_send(ws, JSON.json(Dict("type"=>"builder_file", "content"=>content)))

    elseif cmd == "write_file"
        path    = get(p, "path", "")
        content = get(p, "content", "")
        full    = _project_path(root, path)
        mkpath(dirname(full))
        write(full, content)
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"saved: $path")))

    elseif cmd == "execute"
        code = get(p, "code", "")
        lang = get(p, "lang", "julia")
        tmp  = tempname() * (lang == "python" ? ".py" : ".jl")
        write(tmp, code)
        result = try
            out = IOBuffer()
            cmd_exec = lang == "python" ? `python $tmp` : `$(_julia_command(root)) $tmp`
            run(pipeline(cmd_exec, stdout=out, stderr=out))
            String(take!(out))
        catch e
            "Error: $(string(e))"
        finally
            isfile(tmp) && rm(tmp)
        end
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>result)))

    elseif cmd == "create_file"
        path = get(p, "path", "")
        full = _project_path(root, path)
        mkpath(dirname(full))
        isfile(full) || write(full, "")
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"✅ created: $path")))
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "create_dir"
        path = get(p, "path", "")
        full = _project_path(root, path)
        mkpath(full)
        _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"✅ dir created: $path")))
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "delete_path"
        path = get(p, "path", "")
        full = _project_path(root, path)
        try
            isfile(full) ? rm(full) : isdir(full) && rm(full; recursive=true)
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"🗑️ deleted: $path")))
        catch e
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"❌ delete failed: $(string(e))")))
        end
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "rename_path"
        old_path = get(p, "old_path", "")
        new_path = get(p, "new_path", "")
        old_full = _project_path(root, old_path)
        new_full = _project_path(root, new_path)
        try
            mkpath(dirname(new_full))
            mv(old_full, new_full)
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"✅ renamed: $old_path → $new_path")))
        catch e
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>"❌ rename failed: $(string(e))")))
        end
        _handle_builder_cmd(ws, Dict("cmd"=>"list_tree"))

    elseif cmd == "search_files"
        query = get(p, "query", "")
        results = Dict{String,Vector{Dict{String,Any}}}()
        for (dirpath, dirs, fs) in walkdir(root)
            filter!(d -> d ∉ [".git","__pycache__",".vscode","node_modules"], dirs)
            for f in fs
                any(endswith(f, ext) for ext in [".jl",".json",".toml",".py",".md",".txt",".html",".css",".js"]) || continue
                full = joinpath(dirpath, f)
                rel = replace(relpath(full, root), "\\" => "/")
                try
                    for (i, line) in enumerate(eachline(full))
                        if occursin(query, line)
                            haskey(results, rel) || (results[rel] = Dict{String,Any}[])
                            push!(results[rel], Dict{String,Any}("line"=>i, "text"=>strip(line)))
                            length(results[rel]) >= 10 && break  # cap per file
                        end
                    end
                catch e
                    @debug "Search skipped unreadable file" file=full exception=(e, catch_backtrace())
                end
            end
        end
        _ws_send(ws, JSON.json(Dict("type"=>"search_results", "results"=>results, "query"=>query)))

    elseif cmd == "terminal_exec"
        command = get(p, "command", "")
        result = try
            out = IOBuffer()
            run(pipeline(_shell_command(command), stdout=out, stderr=out))
            String(take!(out))
        catch e
            "Error: $(string(e))"
        end
        _ws_send(ws, JSON.json(Dict("type"=>"terminal_output", "output"=>result)))

    elseif cmd == "list_personas"
        personas_file = joinpath(root, "data", "personas", "Personas.mpf.json")
        names = String[]
        if isfile(personas_file)
            data = JSON.parsefile(personas_file)
            for name in keys(data)
                push!(names, name)
            end
            sort!(names)
        end
        _ws_send(ws, JSON.json(Dict("type"=>"personas_list", "personas"=>names)))

    elseif cmd == "get_settings"
        env_keys = Dict(
            "GEMINI_API_KEY"   => "gemini",
            "XAI_API_KEY"      => "xai",
            "OPENAI_API_KEY"   => "openai",
            "CEREBRAS_API_KEY" => "cerebras",
        )
        statuses = Dict{String,Any}()
        for (env_name, label) in env_keys
            v = get(ENV, env_name, "")
            statuses[label] = Dict(
                "has_key"     => !isempty(v),
                "key_preview" => isempty(v) ? "" :
                    v[1:min(4,length(v))] * "…" * v[max(1,length(v)-3):end]
            )
        end
        _ws_send(ws, JSON.json(Dict("type"=>"settings_all_status", "keys"=>statuses)))

    elseif cmd == "save_settings"
        # Collect all keys being saved this call
        key_map = Dict(
            "GEMINI_API_KEY"   => get(p, "api_key", ""),
            "XAI_API_KEY"      => get(p, "xai_api_key", ""),
            "OPENAI_API_KEY"   => get(p, "openai_api_key", ""),
            "CEREBRAS_API_KEY" => get(p, "cerebras_api_key", ""),
        )
        saved = String[]
        env_path = joinpath(root, ".env")
        lines = isfile(env_path) ? readlines(env_path) : String[]
        for (env_name, val) in key_map
            isempty(val) && continue
            ENV[env_name] = val
            found = false
            for (i, line) in enumerate(lines)
                if startswith(strip(line), "$env_name=")
                    lines[i] = "$env_name=$val"; found = true; break
                end
            end
            !found && push!(lines, "$env_name=$val")
            push!(saved, env_name)
        end
        if !isempty(saved)
            open(env_path, "w") do f
                for line in lines; println(f, line); end
            end
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output",
                "output"=>"✅ Saved: $(join(saved, ", "))")))
            log_settings_change(true, join(saved, ","))
        end
        # Always send back full status so badges update
        env_keys = Dict("GEMINI_API_KEY"=>"gemini","XAI_API_KEY"=>"xai",
                        "OPENAI_API_KEY"=>"openai","CEREBRAS_API_KEY"=>"cerebras")
        statuses = Dict{String,Any}()
        for (env_name, label) in env_keys
            v = get(ENV, env_name, "")
            statuses[label] = Dict("has_key"=>!isempty(v),
                "key_preview"=>isempty(v) ? "" :
                    v[1:min(4,length(v))] * "…" * v[max(1,length(v)-3):end])
        end
        _ws_send(ws, JSON.json(Dict("type"=>"settings_all_status", "keys"=>statuses)))
    end

    catch e
        bt = sprint(showerror, e, catch_backtrace())
        @warn "Builder cmd error" cmd=cmd exception=bt
        log_error("builder_cmd:$cmd", e; stacktrace_str=bt)
        # Send a detailed error to UI (truncated for safety)
        err_msg = "⚠ Error in $cmd: $(first(string(e),200))"
        try
            _ws_send(ws, JSON.json(Dict("type"=>"builder_output", "output"=>err_msg)))
        catch send_err
            @warn "Builder error message could not be forwarded to UI" exception=(send_err, catch_backtrace())
        end
    end
end

function process_message(ws, raw_msg::String, history::Vector, engine)
    global _current_model, _current_gear, _active_modes

    log_ws_message_in(raw_msg)
    p = JSON.parse(raw_msg)

    # --- Forge stream: re-forge edited tool from UI ---
    if get(p, "type", "") == "forge_resubmit"
        name = string(get(p, "name", ""))
        code = string(get(p, "code", ""))
        desc = string(get(p, "description", "Edited via forge stream"))
        if isempty(name) || isempty(code)
            _ws_send(ws, Dict("type"=>"forge_resubmit_result", "error"=>"name and code are required"))
            return
        end
        result = dispatch("forge_new_tool", Dict("name"=>name, "code"=>code, "description"=>desc))
        _ws_send(ws, Dict("type"=>"forge_resubmit_result", "name"=>name, "result"=>result))
        return
    end

    # --- Confirmation response handling ---
    if get(p, "type", "") == "confirm_response"
        cid = get(p, "id", "")
        answer = Bool(p["answer"])
        if haskey(_pending_confirms, cid)
            pending = _pending_confirms[cid]
            delete!(_pending_confirms, cid)
            if answer
                fn = pending["fn"]
                args = pending["args"]
                @info "User confirmed tool $fn"
                _execute_tool_call(ws, engine, fn, args)
            else
                _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>"✅ Action cancelled by user.")))
            end
        else
            @warn "Confirm response with unknown id $cid"
            _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>"⚠️ Unknown confirmation ID.")))
        end
        return
    end

    # Model switch
    if p["type"] == "model_change"
        old = _current_model
        _current_model = p["model"]
        log_model_change(old, _current_model)
        # No special chat‑only notice – we always attempt tool calls.
        notice = "Switched to $(_current_model) 🔧"
        out = Dict("type"=>"tool", "text"=>notice)
        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
        return
    end

    # --- Stop / abort in‑progress generation ---
    if p["type"] == "stop_generation"
        _generation_abort[] = true
        _ws_send(ws, JSON.json(Dict("type"=>"tool", "text"=>"⊣ Generation stopped.")))
        return
    end

    # --- Session history: list past sessions ---
    if p["type"] == "get_history"
        rows = try
            db = SQLite.DB(_runtime_state_path("sparkbyte_memory.db"; root=root))
            r = DBInterface.execute(db, """
                SELECT session_id, started_at, ended_at, events, notes
                FROM sessions ORDER BY started_at DESC LIMIT 50
            """) |> DataFrame
            [Dict("session_id"=>string(r[i,:session_id]),
                  "started_at"=>string(r[i,:started_at]),
                  "ended_at"=>ismissing(r[i,:ended_at]) ? "" : string(r[i,:ended_at]),
                  "events"=>coalesce(r[i,:events],0),
                  "notes"=>coalesce(r[i,:notes],"")) for i in 1:nrow(r)]
        catch e; Dict{String,Any}[]; end
        _ws_send(ws, JSON.json(Dict("type"=>"history_list", "sessions"=>rows)))
        return
    end

    # --- Session history: load a past session's turns ---
    if p["type"] == "load_session"
        sid = get(p, "session_id", "")
        turns = try
            db = SQLite.DB(_runtime_state_path("sparkbyte_memory.db"; root=root))
            r = DBInterface.execute(db, """
                SELECT timestamp, event, turn_number, model, persona, data_json
                FROM telemetry WHERE session_id=?
                AND event IN ('turn_complete','tool_call','tool_result','ws_in')
                ORDER BY timestamp ASC LIMIT 400
            """, (sid,)) |> DataFrame
            [Dict("ts"=>string(r[i,:timestamp]),
                  "role"=>string(r[i,:event]),
                  "content"=>coalesce(r[i,:data_json],""),
                  "model"=>coalesce(r[i,:model],""),
                  "persona"=>coalesce(r[i,:persona],""),
                  "loop_iter"=>coalesce(r[i,:turn_number],0)) for i in 1:nrow(r)]
        catch e; Dict{String,Any}[]; end
        _ws_send(ws, JSON.json(Dict("type"=>"session_turns", "session_id"=>sid, "turns"=>turns)))
        return
    end

    # --- Builder panel commands ---
    if p["type"] == "builder_cmd"
        _handle_builder_cmd(ws, p)
        return
    end

    # --- Server relaunch ---
    if p["type"] == "restart_server"
        _ws_send(ws, JSON.json(Dict("type"=>"tool","text"=>"⟳ Relaunching server — reconnect in ~5s…")))
        @async begin
            sleep(1.0)
            # Spawn a fresh server process detached from this one
            sparkbyte_script = joinpath(dirname(dirname(@__DIR__)), "sparkbyte.jl")
            if !isfile(sparkbyte_script)
                sparkbyte_script = joinpath(dirname(@__DIR__), "sparkbyte.jl")
            end
            if isfile(sparkbyte_script)
                project_dir = dirname(sparkbyte_script)
                if Sys.iswindows()
                    run(`cmd /c start "" julia --project=$project_dir $sparkbyte_script`, wait=false)
                else
                    run(`$(_julia_command(project_dir)) $sparkbyte_script`, wait=false)
                end
            end
            sleep(0.5)
            exit(0)
        end
        return
    end

    # Persona switch
    if p["type"] == "persona_change"
        name = get(p, "persona", "")
        old  = engine.current_persona_name
        ok   = false
        if !isempty(name)
            ok = Main.JLEngine.set_persona!(engine, name)
        end
        log_persona_change(old, name, ok)
        out = Dict("type"=>"tool", "text"=>"⚡ Persona → $name")
        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
        return
    end

    txt       = get(p, "text",  "")
    img       = get(p, "image", nothing)
    mime      = get(p, "mime",  nothing)
    chat_mode = get(p, "chat_mode", false)  # true = no tools, just talk
    # Force‑disable tools for models that don't support function calling
    # (Removed restriction – all models will attempt tool calls; provider may reject.)
    # if !chat_mode && _current_model in _NO_TOOL_MODELS
    #     chat_mode = true
    #     _ws_send(ws, JSON.json(Dict("type"=>"tool",
    #         "text"=>"ℹ️ $(_current_model) doesn't support function calling — running in chat-only mode.")))
    # end

    # Slash commands
    if startswith(txt, "/")
        parts = split(lowercase(strip(txt)))
        cmd   = parts[1]
        args  = length(parts) > 1 ? parts[2:end] : []
        if cmd == "/gear" && !isempty(args)
            gear_up = uppercase(args[1])
            if gear_up in ["LITE_REASONING", "EXPRESSIVE_SYNTH", "TASK_FLOW"]
                _current_gear = gear_up
                log_event("slash_cmd", Dict{String,Any}("cmd"=>"/gear", "value"=>gear_up, "action"=>"gear_override"))
            elseif Main.JLEngine.set_persona!(engine, string(args[1]))
                log_persona_change(engine.current_persona_name, string(args[1]), true)
            end
        end
        out = Dict("type"=>"ui_update", "gear"=>_current_gear, "modes"=>_active_modes)
        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
        return
    end

    turn_start_ms = round(Int, datetime2unix(now()) * 1000)

    # Build user turn
    parts_list = Any[]
    !isempty(txt) && push!(parts_list, Dict("text" => txt))
    img !== nothing && push!(parts_list, Dict("inlineData" => Dict("mimeType"=>mime, "data"=>img)))
    push!(history, Dict("role"=>"user", "parts"=>parts_list))

    # --- JL Engine cognitive snapshot (once per turn) ---
    snapshot = Main.JLEngine.analyze_turn!(engine, txt; persona_name=engine.current_persona_name)
    log_engine_snapshot(snapshot)

    _current_gear  = snapshot["gait"]
    _active_modes  = [snapshot["rhythm"]["mode"],
                      snapshot["aperture_state"]["mode"],
                      snapshot["behavior_state"]["name"]]
    out_ui = Dict("type"=>"ui_update", "gear"=>uppercase(_current_gear), "modes"=>_active_modes)
    _ws_send(ws, JSON.json(out_ui)); log_ws_message_out(out_ui)

    boot_prompt = Main.JLEngine.get_llm_boot_prompt(engine)
    sys_prompt  = boot_prompt *
        "\n\n--- JL ENGINE COGNITIVE STATE ---\n" *
        "GAIT: $(_current_gear)\n" *
        "RHYTHM MODE: $(snapshot["rhythm"]["mode"])\n" *
        "EMOTIONAL APERTURE: $(snapshot["aperture_state"]["mode"])\n" *
        "BEHAVIOR STATE: $(snapshot["behavior_state"]["name"])\n" *
        "DRIFT PRESSURE: $(round(snapshot["drift"]["pressure"]; digits=3))\n" *
        "ADVISORY: $(get(snapshot["advisory"], "msg", "None"))" *
        "\n\n" * _build_self_context(engine)

    # ── Provider profiles ───────────────────────────────────────────────────
    # Single source of truth for every provider's capabilities and wire‑up.
    # Add a new provider here — nowhere else.
    PROVIDER_PROFILES = Dict{String,Dict{String,Any}}(
        "gemini" => Dict(
            "endpoint"        => "",                          # built dynamically per model
            "env_key"         => "GEMINI_API_KEY",
            "supports_tools"  => true,
            "supports_top_p"  => true,
            "supports_vision" => true,
            "schema_format"   => "gemini",                   # UPPERCASE types, function_declarations wrapper
            "uses_gemini_api" => true,
        ),
        "xai" => Dict(
            "endpoint"        => "https://api.x.ai/v1/chat/completions",
            "env_key"         => "XAI_API_KEY",
            "supports_tools"  => true,
            "supports_top_p"  => true,
            "supports_vision" => false,
            "schema_format"   => "openai",
            "uses_gemini_api" => false,
        ),
        "xai_responses" => Dict(
            "endpoint"           => "https://api.x.ai/v1/responses",
            "env_key"            => "XAI_API_KEY",
            "supports_tools"     => true,
            "supports_top_p"     => false,
            "supports_vision"    => false,
            "schema_format"      => "openai",
            "uses_responses_api" => true,
            "uses_gemini_api"    => false,
        ),
        "openai" => Dict(
            "endpoint"        => "https://api.openai.com/v1/chat/completions",
            "env_key"         => "OPENAI_API_KEY",
            "supports_tools"  => true,
            "supports_top_p"  => true,
            "supports_vision" => true,
            "schema_format"   => "openai",
            "uses_gemini_api" => false,
        ),
        "cerebras" => Dict(
            "endpoint"        => "https://api.cerebras.ai/v1/chat/completions",
            "env_key"         => "CEREBRAS_API_KEY",
            "supports_tools"  => true,
            "supports_top_p"  => false,                      # Cerebras rejects top_p
            "supports_vision" => false,
            "schema_format"   => "openai",
            "max_temp"        => 1.5,
            "uses_gemini_api" => false,
        ),
        "ollama" => Dict(
            "endpoint"        => _ollama_openai_endpoint(),
            "env_key"         => "",                          # no key needed
            "supports_tools"  => true,
            "supports_top_p"  => true,
            "supports_vision" => false,
            "schema_format"   => "openai",
            "uses_gemini_api" => false,
        ),
    )

    # ── Model → provider routing ──────────────────────────────────────────────
    # Explicit model lists win. Prefix matching is the fallback.
    _XAI_RESPONSES_MODELS = ["grok-4.20-multi-agent-0309", "grok-4.20-reasoning"]
    _XAI_RESPONSES_NO_TOOL_MODELS = Set(["grok-4.20-multi-agent-0309"])
    _CEREBRAS_MODELS = [
        "llama-4-scout-17b-16e-instruct", "llama-4-maverick-17b-128e-instruct",
        "llama3.3-70b", "llama3.1-70b", "llama3.1-8b",
        "qwen-3-32b", "gpt-oss-120b", "gpt-oss-70b",
    ]
    provider = if _current_model in _XAI_RESPONSES_MODELS;  "xai_responses"
    elseif _current_model in _CEREBRAS_MODELS;              "cerebras"
    elseif startswith(_current_model, "grok-");             "xai"
    elseif startswith(_current_model, "gpt-") || startswith(_current_model, "o4-") || startswith(_current_model, "o3-"); "openai"
    elseif startswith(_current_model, "ollama:");           "ollama"
    else;                                                   "gemini"
    end
    pp = PROVIDER_PROFILES[provider]

    # ── Params ───────────────────────────────────────────────────────────────
    temp  = clamp(get(snapshot["aperture_state"],"temp",0.45) +
                  get(snapshot["drift"],"temperature_delta",0.0), 0.1, 1.5)
    top_p = clamp(get(snapshot["aperture_state"],"top_p",0.7), 0.1, 1.0)

    # Gemini-specific generation config
    safety = [Dict("category"=>"HARM_CATEGORY_$c", "threshold"=>"BLOCK_NONE")
              for c in ["HATE_SPEECH","HARASSMENT","DANGEROUS_CONTENT","SEXUALLY_EXPLICIT","CIVIC_INTEGRITY"]]
    gen_config = Dict{String,Any}("temperature"=>temp, "topP"=>top_p)
    if occursin("thinking", lowercase(_current_model)) || _current_model == "gemma-4-26b-a4b-it"
        gen_config["thinking_config"] = Dict("thinking_level"=>"HIGH")
    elseif _current_model == "gemini-3.1-flash-lite-preview"
        gen_config["thinking_config"] = Dict("thinking_level"=>"MINIMAL")
    end

    log_system_prompt(sys_prompt, snapshot)
    log_param_decision(gen_config, snapshot)

    # ── Schema normalizer ─────────────────────────────────────────────────────
    # Gemini uses UPPERCASE JSON schema types (STRING, OBJECT, ARRAY…)
    # OAI providers require lowercase (string, object, array…)
    # This runs recursively so forged tools get the same treatment.
    function _normalize_schema(v::Dict)
        out = Dict{String,Any}()
        obj_schema = false
        for (k, val) in v
            if k == "type" && val isa String
                lowered = lowercase(val)
                out[k] = lowered
                obj_schema = lowered == "object"
            elseif val isa Dict
                out[k] = _normalize_schema(val)
            elseif val isa Vector
                out[k] = [x isa Dict ? _normalize_schema(x) : x for x in val]
            else
                out[k] = val
            end
        end
        if obj_schema
            props = get(out, "properties", Dict{String,Any}())
            out["properties"] = props isa AbstractDict ? Dict{String,Any}(string(pk) => pv for (pk, pv) in pairs(props)) : Dict{String,Any}()
            req = get(out, "required", Any[])
            out["required"] = req isa AbstractVector ? collect(req) : Any[]
        end
        out
    end
    _normalize_schema(v) = v   # passthrough for non‑Dict

    # Build tool schemas in the format the current provider needs
    all_decls_raw = vcat(TOOLS_SCHEMA[1]["function_declarations"], DYNAMIC_SCHEMA)
    oai_tools = [Dict("type"=>"function",
                      "function"=>Dict(
                          "name"        => d["name"],
                          "description" => get(d, "description", ""),
                          "parameters"  => _normalize_schema(get(d, "parameters", Dict()))))
                 for d in all_decls_raw]

    # --- Agentic tool loop ---
    final_reply = ""
    loop_iter   = 0
    prior_history = isempty(history) ? Any[] : history[1:end-1]
    max_tool_loops = 12
    max_repeat_tool_calls = 4
    tool_guard_hit = false
    last_tool_signature = ""
    same_tool_streak = 0
    last_tool_name_used = ""
    last_tool_elapsed_used = 0

    function _stable_tool_repr(v)
        if v isa AbstractDict
            items = sort(collect(pairs(v)); by = kv -> string(first(kv)))
            return "{" * join(["$(string(k)):$(_stable_tool_repr(val))" for (k, val) in items], ",") * "}"
        elseif v isa AbstractVector
            return "[" * join([_stable_tool_repr(x) for x in v], ",") * "]"
        end
        return string(v)
    end

    function _trip_tool_guard(reason::AbstractString)
        tool_guard_hit && return
        tool_guard_hit = true
        guard_text = "⚠️ Tool loop guard tripped: $(reason). I stopped the tool spam instead of hanging the UI."
        final_reply = guard_text
        out_guard = Dict("type"=>"spark", "text"=>guard_text)
        _ws_send(ws, JSON.json(out_guard)); log_ws_message_out(out_guard)
        log_event("tool_loop_guard", Dict{String,Any}(
            "reason" => string(reason),
            "loop_iter" => Int(loop_iter),
            "model" => string(_current_model),
            "persona" => string(engine.current_persona_name),
        ))
    end

    function _allow_tool_call(name::AbstractString, args)
        sig = string(name) * ":" * _stable_tool_repr(args)
        if sig == last_tool_signature
            same_tool_streak += 1
        else
            last_tool_signature = sig
            same_tool_streak = 1
        end
        if same_tool_streak >= max_repeat_tool_calls
            _trip_tool_guard("repeated `$name` call $(same_tool_streak)x in a row")
            return false
        end
        return true
    end

    # OAI path: build oai_messages ONCE here and append to it each iteration.
    # Never rebuild from history mid‑loop — that loses real tool_call_ids from
    # OAI responses and breaks the tool roundtrip on iteration 2+.
    oai_messages = Any[Dict("role"=>"system","content"=>sys_prompt)]
    if provider != "gemini" && provider != "xai_responses"
        for h in prior_history
            role = get(h,"role","user") == "model" ? "assistant" : get(h,"role","user")
            if role == "function"
                for part in get(h,"parts",[])
                    fr = get(part,"functionResponse",nothing)
                    fr === nothing && continue
                    # Prior‑turn tool results use name as id — fine for history seeding,
                    # only current‑turn ids need to be exact (handled in‑loop below)
                    push!(oai_messages, Dict("role"=>"tool",
                        "tool_call_id"=>get(fr,"name","unknown"),
                        "content"=>JSON.json(get(fr,"response",Dict()))))
                end
            else
                content_blocks = Any[]
                for part in get(h,"parts",[])
                    get(part,"thought",false) && continue
                    if haskey(part,"text") && !isempty(part["text"])
                        push!(content_blocks, Dict("type"=>"text","text"=>part["text"]))
                    elseif haskey(part,"inlineData")
                        id2 = part["inlineData"]
                        push!(content_blocks, Dict("type"=>"image_url",
                            "image_url"=>Dict("url"=>"data:$(id2["mimeType"]);base64,$(id2["data"])")))
                    end
                end
                isempty(content_blocks) && continue
                has_img = any(b->get(b,"type","")=="image_url", content_blocks)
                msg_content = has_img ? content_blocks :
                    join([b["text"] for b in content_blocks if get(b,"type","")=="text"], "\n")
                push!(oai_messages, Dict("role"=>role,"content"=>msg_content))
            end
        end
        # Append the current user turn (with optional image)
        cur_blocks = Any[Dict("type"=>"text","text"=>txt)]
        if img !== nothing
            push!(cur_blocks, Dict("type"=>"image_url",
                "image_url"=>Dict("url"=>"data:$(mime);base64,$(img)")))
        end
        has_cur_img = img !== nothing
        push!(oai_messages, Dict("role"=>"user",
            "content"=> has_cur_img ? cur_blocks : txt))
    end

    _generation_abort[] = false   # reset at start of every new turn
    while true
        if _generation_abort[]
            _generation_abort[] = false
            _ws_send(ws, JSON.json(Dict("type"=>"spark", "text"=>"\n\n⊣ *Aborted.*")))
            break
        end
        loop_iter += 1
        log_api_request(_current_model, gen_config, length(history), loop_iter)
        try
        if provider == "gemini"
            # ── Gemini path ──────────────────────────────────────────────────
            api_key = get(ENV, "GEMINI_API_KEY", "")
            api_url = "https://generativelanguage.googleapis.com/v1beta/models/$(_current_model):generateContent?key=$api_key"
            payload = if chat_mode
                Dict("system_instruction"=>Dict("parts"=>[Dict("text"=>sys_prompt)]),
                     "contents"=>history, "safetySettings"=>safety, "generation_config"=>gen_config)
            else
                Dict("system_instruction"=>Dict("parts"=>[Dict("text"=>sys_prompt)]),
                     "contents"=>history, "safetySettings"=>safety, "generation_config"=>gen_config,
                     "tools"=>[Dict("function_declarations"=>all_decls_raw)])
            end
            resp = HTTP.post(api_url, ["Content-Type"=>"application/json"], JSON.json(payload))
            data = JSON.parse(String(resp.body))
            log_token_usage(get(data, "usageMetadata", nothing), loop_iter)
            cand = (haskey(data,"candidates") && !isempty(data["candidates"])) ? data["candidates"][1] : nothing
            if cand !== nothing; log_safety_ratings(get(cand,"safetyRatings",[]), loop_iter); end
            if cand !== nothing && haskey(cand, "content")
                m = cand["content"]; finish_reason = get(cand,"finishReason","UNKNOWN")
                push!(history, m)
                has_tool = false
                for part in m["parts"]
                    if haskey(part,"thought") && part["thought"] == true
                        raw_thinking = get(part,"text","")
                        log_thinking(raw_thinking, loop_iter)
                        # Show thinking bubble in UI then finalize it
                        _ws_send(ws, JSON.json(Dict("type"=>"thinking","text"=>first(raw_thinking,300))))
                        _ws_send(ws, JSON.json(Dict("type"=>"thinking_done",
                            "text"=>raw_thinking, "chars"=>length(raw_thinking))))
                        @async _db_write_reasoning(first(txt,120), raw_thinking, _current_model,
                            string(engine.current_persona_name))
                    elseif haskey(part,"text")
                        final_reply *= part["text"]
                        out = Dict("type"=>"spark","text"=>part["text"])
                        _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
                        log_api_response(_current_model, resp.status, length(resp.body), loop_iter;
                            has_text=true, text_preview=part["text"], finish_reason=string(finish_reason))
                    elseif haskey(part,"functionCall")
                        has_tool = true; c = part["functionCall"]; args = get(c,"args",Dict())
                        println("⚡ BYTE tool: $(c["name"])")
                        # Confirmation step
                        if REQUIRE_CONFIRM[]
                            cid = string(uuid4())
                            _pending_confirms[cid] = Dict("fn"=>c["name"], "args"=>args)
                            _ws_send(ws, JSON.json(Dict("type"=>"confirm","id"=>cid,
                                "text"=>"⚠️ Run tool **$(c["name"])** with args $(JSON.json(args))?")))
                            # Skip actual execution now – will resume on confirm_response
                            continue
                        end
                        res, elapsed = _execute_tool_call(ws, engine, c["name"], args; loop_iter=loop_iter)
                        last_tool_name_used = c["name"]; last_tool_elapsed_used = elapsed
                        # Append tool result with the EXACT same tc_id — this is the roundtrip
                        push!(history, Dict("role"=>"function","parts"=>[Dict(
                            "functionResponse"=>Dict("name"=>c["name"],"response"=>Dict("content"=>res)))]))
                    end
                end
                !has_tool && break
            else
                err_msg = "ERROR: No response from Gemini. $(get(data,"error",Dict{String,Any}()))"
                _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>err_msg)))
                log_api_response(_current_model, resp.status, length(resp.body), loop_iter;
                    error=err_msg)
                break
            end

        else
            # ── OpenAI‑compatible path (Grok/xAI, OpenAI, Ollama) ────────────
            # AND xAI Responses API path
            if provider == "xai_responses"
                # ── xAI /v1/responses API ────────────────────────────────────
                api_key = get(ENV, "XAI_API_KEY", "")
                if isempty(api_key)
                    _ws_send(ws, JSON.json(Dict("type"=>"spark",
                        "text"=>"⚠️ No XAI_API_KEY set. Add it in Settings."))); break
                end

                # Build input messages array (carries history across loop iterations)
                if loop_iter == 1
                    # First iteration — build full history
                    input_msgs = Any[]
                    for h in history
                        h_role = get(h,"role","user") == "model" ? "assistant" : "user"
                        blocks = Any[]
                        for part in get(h,"parts",[])
                            get(part,"thought",false) && continue
                            if haskey(part,"text") && !isempty(part["text"])
                                push!(blocks, Dict("type"=>"input_text","text"=>part["text"]))
                            elseif haskey(part,"inlineData")
                                id2 = part["inlineData"]
                                push!(blocks, Dict("type"=>"input_image",
                                    "image_url"=>"data:$(id2["mimeType"]);base64,$(id2["data"])"))
                            end
                        end
                        isempty(blocks) && continue
                        push!(input_msgs, Dict("role"=>h_role,"content"=>blocks))
                    end
                    # Current user turn with optional image
                    cur_blocks = Any[Dict("type"=>"input_text","text"=>txt)]
                    img !== nothing && push!(cur_blocks, Dict("type"=>"input_image",
                        "image_url"=>"data:$(mime);base64,$(img)"))
                    push!(input_msgs, Dict("role"=>"user","content"=>cur_blocks))
                end  # on subsequent iterations input_msgs has tool results appended below

                # Build tools for Responses API
                # xAI Responses API tool format: flat — name/description/parameters at top level
                # NOT nested under "function" like OAI chat/completions
                xai_tools_enabled = !chat_mode
                if xai_tools_enabled && (_current_model in _XAI_RESPONSES_NO_TOOL_MODELS)
                    xai_tools_enabled = false
                    warn = Dict("type"=>"tool",
                        "text"=>"ℹ xAI tool calls are gated for $_current_model on this account; falling back to chat-only mode.")
                    _ws_send(ws, JSON.json(warn)); log_ws_message_out(warn)
                end

                xai_resp_tools = xai_tools_enabled ? [Dict(
                    "type"        => "function",
                    "name"        => d["name"],
                    "description" => get(d,"description",""),
                    "parameters"  => _normalize_schema(get(d,"parameters",Dict()))
                ) for d in all_decls_raw] : Any[]

                payload = Dict{String,Any}(
                    "model"        => _current_model,
                    "stream"       => false,
                    "instructions" => sys_prompt,
                    "input"        => input_msgs,
                )
                if !isempty(xai_resp_tools)
                    payload["tools"] = xai_resp_tools
                    payload["tool_choice"] = "auto"
                end

                headers = ["Content-Type"=>"application/json", "Authorization"=>"Bearer $api_key"]
                resp = HTTP.post("https://api.x.ai/v1/responses", headers, JSON.json(payload))
                data = JSON.parse(String(resp.body))

                # Capture reasoning if present
                rsn_obj = get(data, "reasoning", nothing)
                if !isnothing(rsn_obj) && rsn_obj isa Dict
                    rsn_parts = String[]
                    for s in get(rsn_obj, "summary", [])
                        s isa Dict && haskey(s,"text") && push!(rsn_parts, s["text"])
                    end
                    effort = get(rsn_obj, "effort", nothing)
                    rsn = isempty(rsn_parts) ? (isnothing(effort) ? "" : "effort: $effort") :
                          (isnothing(effort) ? join(rsn_parts,"\n") : "effort: $effort\n\n"*join(rsn_parts,"\n"))
                    if !isempty(rsn)
                        _ws_send(ws, JSON.json(Dict("type"=>"thinking","text"=>first(rsn,300))))
                        _ws_send(ws, JSON.json(Dict("type"=>"thinking_done","text"=>rsn,"chars"=>length(rsn))))
                        @async _db_write_reasoning(first(txt,120), rsn, _current_model, string(engine.current_persona_name))
                    end
                end

                # Parse output — collect text and tool calls
                reply_text = ""
                xai_tool_calls = Any[]
                output_items = get(data, "output", Any[])
                for item in output_items
                    itype = get(item,"type","")
                    if itype == "message"
                        for c in get(item,"content",[])
                            get(c,"type","") == "output_text" && (reply_text *= get(c,"text",""))
                        end
                    elseif itype == "function_call"
                        push!(xai_tool_calls, item)
                    end
                end

                # Stream any text reply to UI
                if !isempty(reply_text)
                    final_reply *= reply_text
                    push!(history, Dict("role"=>"model","parts"=>[Dict("text"=>reply_text)]))
                    out = Dict("type"=>"spark","text"=>reply_text)
                    _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
                    log_api_response(_current_model, resp.status, length(resp.body), loop_iter;
                        has_text=true, text_preview=reply_text, finish_reason="stop")
                end

                # Handle tool calls
                if isempty(xai_tool_calls)
                    isempty(reply_text) && _ws_send(ws, JSON.json(Dict("type"=>"spark",
                        "text"=>"⚠️ No output from xAI Responses API.")))
                    break
                end

                # Append assistant's tool_call items to input for next round
                for tc in xai_tool_calls
                    push!(input_msgs, tc)
                end

                # Execute each tool and append results
                for tc in xai_tool_calls
                    fn_name = get(tc,"name","")
                    call_id = get(tc,"call_id","")
                    args_raw = get(tc,"arguments","{}")
                    args_parsed = try JSON.parse(args_raw) catch; Dict{String,Any}() end
                    # Confirmation step
                    if REQUIRE_CONFIRM[]
                        cid = string(uuid4())
                        _pending_confirms[cid] = Dict("fn"=>fn_name, "args"=>args_parsed)
                        _ws_send(ws, JSON.json(Dict("type"=>"confirm","id"=>cid,
                            "text"=>"⚠️ Run tool **$fn_name** with args $(JSON.json(args_parsed))?")))
                        continue
                    end
                    result_dict, _elapsed_xai = _execute_tool_call(ws, engine, fn_name, args_parsed; loop_iter=loop_iter)
                    result_str = JSON.json(result_dict)
                    push!(input_msgs, Dict(
                        "type"    => "function_call_output",
                        "call_id" => call_id,
                        "output"  => result_str,
                    ))
                end
                # Loop again with tool results in input_msgs

            else
            # ── OAI‑compatible path (xAI, OpenAI, Cerebras, Ollama) ──────────
            # All config comes from the provider profile — no scattered if/else here.
            # oai_messages was built once before the loop and is appended to in‑place —
            # tool_call_ids from OAI responses are preserved exactly across iterations.
            api_url = pp["endpoint"]
            env_key = pp["env_key"]
            api_key = isempty(env_key) ? "ollama" : get(ENV, env_key, "")
            if isempty(api_key)
                wrn = "⚠️ No API key set for provider '$provider' (env: $env_key). Add it in Settings."
                _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>wrn))); break
            end

            actual_model = provider == "ollama" ? replace(_current_model,"ollama:"=>"") : _current_model

            # Build payload from profile — profile is the single source of truth
            payload = Dict{String,Any}("model"=>actual_model, "messages"=>oai_messages,
                                       "temperature"=>temp)
            pp["supports_top_p"] && (payload["top_p"] = top_p)
            if !chat_mode && pp["supports_tools"]
                payload["tools"]       = oai_tools
                payload["tool_choice"] = "auto"
            end
            # gpt‑oss models on Cerebras support reasoning_effort
            if provider == "cerebras" && startswith(_current_model, "gpt-oss")
                payload["reasoning_effort"] = "medium"
            end

            headers = ["Content-Type"=>"application/json", "Authorization"=>"Bearer $api_key"]
            resp = HTTP.post(api_url, headers, JSON.json(payload))
            data = JSON.parse(String(resp.body))

            if !haskey(data,"choices") || isempty(data["choices"])
                err_msg = "ERROR: No response from $provider. $(get(data,"error",Dict{String,Any}()))"
                _ws_send(ws, JSON.json(Dict("type"=>"spark","text"=>err_msg)))
                log_api_response(_current_model, resp.status, length(resp.body), loop_iter; error=err_msg)
                break
            end

            msg           = data["choices"][1]["message"]
            finish_reason = get(data["choices"][1],"finish_reason","unknown")
            has_tool      = false

            if haskey(msg,"tool_calls") && !isnothing(msg["tool_calls"]) && !isempty(msg["tool_calls"])
                has_tool = true
                # Push the full assistant message (with its tool_calls array) into oai_messages.
                # The exact ids from this message will be echoed back in the tool result messages below —
                # that's what makes the roundtrip work on iteration 2+.
                push!(oai_messages, msg)

                for tc in msg["tool_calls"]
                    fn      = tc["function"]
                    tc_id   = get(tc,"id","call_$(fn["name"])")   # exact id from OAI response
                    tc_name = fn["name"]
                    tc_args = try JSON.parse(get(fn,"arguments","{}")) catch; Dict() end
                    println("⚡ BYTE tool ($provider): $tc_name")
                    # Confirmation step
                    if REQUIRE_CONFIRM[]
                        cid = string(uuid4())
                        _pending_confirms[cid] = Dict("fn"=>tc_name, "args"=>tc_args)
                        _ws_send(ws, JSON.json(Dict("type"=>"confirm","id"=>cid,
                            "text"=>"⚠️ Run tool **$tc_name** with args $(JSON.json(tc_args))?")))
                        continue
                    end
                    res, elapsed = _execute_tool_call(ws, engine, tc_name, tc_args; loop_iter=loop_iter)
                    last_tool_name_used = tc_name; last_tool_elapsed_used = elapsed
                    # Append tool result with the EXACT same tc_id — this is the roundtrip
                    push!(oai_messages, Dict("role"=>"tool","tool_call_id"=>tc_id,"content"=>JSON.json(res)))
                end
            elseif haskey(msg,"content") && !isnothing(msg["content"])
                txt = string(msg["content"])
                final_reply *= txt
                push!(history, Dict("role"=>"model","parts"=>[Dict("text"=>txt)]))
                out = Dict("type"=>"spark","text"=>txt)
                _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
                log_api_response(_current_model, resp.status, length(resp.body), loop_iter;
                    has_text=true, text_preview=txt, finish_reason=finish_reason)
            end

            !has_tool && break
        end  # xai_responses else (OAI‑compatible)
        end  # provider branch

        catch e
            bt  = sprint(showerror, e, catch_backtrace())
            msg = "FAILURE: $(first(_redact_sensitive_text(e), 300))"
            out = Dict("type"=>"spark", "text"=>msg)
            _ws_send(ws, JSON.json(out)); log_ws_message_out(out)
            log_error("api_loop:iter_$loop_iter", e; stacktrace_str=bt)
            break
        end
    end

    # Feed output back to engine memory + log turn complete
    !isempty(final_reply) && Main.JLEngine.record_turn!(engine, txt, final_reply; snapshot=snapshot)
    elapsed_total = round(Int, datetime2unix(now()) * 1000) - turn_start_ms
    log_turn_complete(txt, length(final_reply), loop_iter, elapsed_total)

    # Telemetry broadcast — drives the live panel in the UI
    try
        drift_p = round(get(get(snapshot, "drift", Dict{String,Any}()), "pressure", 0.0); digits=3)
        telem = Dict{String,Any}(
            "type"            => "telemetry_update",
            "gait"            => string(get(snapshot, "gait", _current_gear)),
            "rhythm_mode"     => string(get(get(snapshot,"rhythm",Dict{String,Any}()),"mode","—")),
            "aperture_mode"   => string(get(get(snapshot,"aperture_state",Dict{String,Any}()),"mode","—")),
            "behavior_state"  => string(get(get(snapshot,"behavior_state",Dict{String,Any}()),"name","—")),
            "drift_pressure"  => drift_p,
            "stability_score" => round(engine.stability_score; digits=3),
            "loop_count"      => Int(loop_iter),
            "last_tool"       => last_tool_name_used,
            "last_tool_ms"    => last_tool_elapsed_used,
            "persona"         => string(engine.current_persona_name),
            "model"           => string(_current_model),
            "elapsed_ms"      => elapsed_total,
        )
        _ws_send(ws, JSON.json(telem))
    catch e
        @warn "Telemetry update push failed" exception=(e, catch_backtrace())
    end

    # Live memory: write thought diary entry to SQLite + flush session event count
    @async try
        behavior   = get(snapshot, "behavior_state", Dict())
        tone       = string(get(behavior, "tone_bias", "personable"))
        bname      = string(get(behavior, "name", "Engaged-Loose"))
        mood       = replace(lowercase(bname), r"[^a-z/]" => "-")
        gait       = string(get(snapshot, "gait", "walk"))
        persona    = string(engine.current_persona_name)
        thought    = "Responded to: \"$(first(txt, 120))\". " *
                     "Reply ($(length(final_reply)) chars): $(first(final_reply, 220)). " *
                     "Tone: $tone. Loops: $loop_iter. Elapsed: $(elapsed_total)ms."
        _db_write_thought(first(txt, 80), thought, mood, gait, persona)
        # Flush live event count to sessions table — survives force kills
        db = _state[:db]
        db !== nothing && SQLite.execute(db,
            "UPDATE sessions SET events=? WHERE session_id=? AND ended_at IS NULL",
            (_session_event_count[], _session_id))
    catch e
        @warn "Failed to persist live thought snapshot" exception=(e, catch_backtrace())
    end
end

"""
    launch(port=8081)

Open Chrome pointed at the app. Falls back to system default browser.
"""
function launch(port::Int=8081)
    url = "http://localhost:$port"
    cmd = if Sys.iswindows()
        chrome = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
        isfile(chrome) ? `cmd /c start "" "$chrome" --app=$url` : `cmd /c start $url`
    elseif Sys.isapple()
        `open $url`
    else
        launcher = Sys.which("xdg-open")
        if launcher !== nothing
            `$launcher $url`
        else
            launcher = Sys.which("gio")
            launcher === nothing ? nothing : `$launcher open $url`
        end
    end
    cmd === nothing && return println("⚠️ No browser launcher found. Open $url manually.")
    run(cmd)
end

"""
    serve(engine; host="127.0.0.1", port=8081)

Start the HTTP + WebSocket server. Blocks forever.
"""
function serve(engine; host::String="127.0.0.1", port::Int=8081)
    println("⚡ BYTE serving on $host:$port")
    log_event("server_start", Dict{String,Any}("host"=>host, "port"=>port))
    _db_start_session(_session_id)
    HTTP.serve(host, port, stream=true) do stream
        if HTTP.WebSockets.isupgrade(stream.message)
            HTTP.WebSockets.upgrade(stream) do ws
                cid = objectid(ws)
                lock(_WS_CLIENTS_LOCK) do; _WS_CLIENTS[cid] = ws; end
                log_event("ws_connect", Dict{String,Any}())
                history = Any[]
                for msg in ws
                    try
                        process_message(ws, String(msg), history, engine)
                    catch e
                        bt = sprint(showerror, e, catch_backtrace())
                        @warn "WS message error" exception=bt
                        log_error("ws_loop", e; stacktrace_str=bt)
                        # Forward a concise error to the UI instead of silently dropping
                        try
                            _ws_send(ws, JSON.json(Dict(
                                "type"=>"builder_output",
                                "output"=>"⚠ Server error: $(first(string(e),200))")))
                        catch send_err
                            @warn "Failed to forward WS loop error to UI" exception=(send_err, catch_backtrace())
                        end
                    end
                end
                lock(_WS_CLIENTS_LOCK) do; delete!(_WS_CLIENTS, cid); end
                log_event("ws_disconnect", Dict{String,Any}())
            end
        else
            req = stream.message
            if req.target == "/health" || startswith(req.target, "/health?") || req.target == "/healthz" || startswith(req.target, "/healthz?")
                log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>200))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"=>"application/json; charset=utf-8")
                HTTP.startwrite(stream)
                write(stream, JSON.json(Dict(
                    "status" => "ok",
                    "service" => "sparkbyte",
                    "persona" => string(engine.current_persona_name),
                    "session_id" => _session_id,
                    "time" => string(now()),
                )))
            elseif req.target == "/"
                log_event("http_serve", Dict{String,Any}("path"=>"/", "status"=>200))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type"=>"text/html; charset=utf-8")
                HTTP.startwrite(stream)
                write(stream, UI_HTML)
            else
                log_event("http_serve", Dict{String,Any}("path"=>req.target, "status"=>404))
                HTTP.setstatus(stream, 404)
                HTTP.setheader(stream, "Content-Type"=>"text/plain")
                HTTP.startwrite(stream)
                write(stream, "Not Found")
            end
        end
    end
end

end # module BYTE
