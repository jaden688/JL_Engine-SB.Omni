# a2a_server.jl — JL Engine A2A (Agent-to-Agent) HTTP endpoint
# Runs on port 8082 alongside SparkByte (8081)
# Implements Google A2A protocol: https://google.github.io/A2A
#
# Endpoints:
#   GET  /.well-known/agent.json   — Agent Card (discovery)
#   POST /                          — JSON-RPC 2.0 task handler
#   GET  /tasks/:id                 — Task status lookup
#   GET  /health                    — Health check

using HTTP
using JSON
using SQLite
using DataFrames
using UUIDs
using Dates

# ─────────────────────────────────────────────
#  Config
# ─────────────────────────────────────────────

const A2A_PORT        = parse(Int, get(ENV, "A2A_PORT", "8082"))
const A2A_HOST        = get(ENV, "A2A_HOST", "0.0.0.0")
const A2A_PUBLIC_URL  = get(ENV, "A2A_PUBLIC_URL", "http://localhost:$A2A_PORT")
const A2A_API_KEY     = get(ENV, "A2A_API_KEY", "")   # empty = open (dev mode)
const A2A_AGENT_NAME  = get(ENV, "A2A_AGENT_NAME", "JL Engine")
const A2A_VERSION     = "1.0.0"

# ─────────────────────────────────────────────
#  SQLite task log
# ─────────────────────────────────────────────

function _a2a_init_db!(db::SQLite.DB)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS a2a_tasks (
            id          TEXT PRIMARY KEY,
            created_at  TEXT NOT NULL,
            api_key     TEXT,
            input       TEXT,
            tool        TEXT,
            args        TEXT,
            status      TEXT DEFAULT 'pending',
            result      TEXT,
            error       TEXT,
            elapsed_ms  INTEGER,
            completed_at TEXT
        )
    """)
end

function _a2a_log_task!(db, id, api_key, input, tool, args)
    SQLite.execute(db,
        "INSERT OR IGNORE INTO a2a_tasks (id, created_at, api_key, input, tool, args, status) VALUES (?,?,?,?,?,?,?)",
        (id, string(now()), api_key, input, tool, JSON.json(args), "running"))
end

function _a2a_complete_task!(db, id, result, elapsed_ms)
    SQLite.execute(db,
        "UPDATE a2a_tasks SET status='completed', result=?, elapsed_ms=?, completed_at=? WHERE id=?",
        (JSON.json(result), elapsed_ms, string(now()), id))
end

function _a2a_fail_task!(db, id, error_msg, elapsed_ms)
    SQLite.execute(db,
        "UPDATE a2a_tasks SET status='failed', error=?, elapsed_ms=?, completed_at=? WHERE id=?",
        (error_msg, elapsed_ms, string(now()), id))
end

function _a2a_get_task(db, id)
    rows = SQLite.DBInterface.execute(db,
        "SELECT id, status, result, error, created_at, completed_at, elapsed_ms, tool FROM a2a_tasks WHERE id=?",
        (id,)) |> DataFrame
    isempty(rows) && return nothing
    r = rows[1, :]
    return Dict(
        "id"           => r.id,
        "status"       => r.status,
        "result"       => isnothing(r.result) ? nothing : JSON.parse(r.result),
        "error"        => r.error,
        "created_at"   => r.created_at,
        "completed_at" => r.completed_at,
        "elapsed_ms"   => r.elapsed_ms,
        "tool"         => r.tool,
    )
end

# ─────────────────────────────────────────────
#  Agent Card
# ─────────────────────────────────────────────

function _agent_card()
    # Auto-generate skills from live BYTE schema — always in sync, never stale
    skills = map(BYTE.TOOLS_SCHEMA[1]["function_declarations"]) do decl
        name = string(get(decl, "name", ""))
        desc = string(get(decl, "description", ""))
        # Tag inference from name/description keywords
        tags = String[]
        contains(name, "file")      && push!(tags, "file", "io")
        contains(name, "code")      && push!(tags, "code", "execute")
        contains(name, "command")   && push!(tags, "shell")
        contains(name, "browse") || contains(name, "playwright") && push!(tags, "web", "browser")
        contains(name, "github")    && push!(tags, "github", "code")
        contains(name, "memory") || name in ("remember","recall") && push!(tags, "memory")
        contains(name, "forge")     && push!(tags, "meta", "self-extending")
        contains(name, "sms")       && push!(tags, "sms", "notify")
        contains(name, "discord")   && push!(tags, "discord", "community", "notify")
        contains(name, "pages")     && push!(tags, "deploy", "web", "github")
        contains(name, "bluetooth") && push!(tags, "hardware", "bluetooth")
        contains(name, "persona") || contains(name, "card") && push!(tags, "persona")
        isempty(tags) && push!(tags, "utility")
        Dict("id" => name, "name" => titlecase(replace(name, "_" => " ")), "description" => first(desc, 120), "tags" => unique(tags))
    end

    return Dict(
        "name"        => A2A_AGENT_NAME,
        "description" => "Julia-native AI agent engine with behavioral middleware stack (DriftPressure, RhythmEngine, EmotionalAperture), persistent SQLite memory, self-extending tool forge, full browser automation, Discord/SMS outreach, and GitHub Pages deployment. Built on JL Engine — runs at native speed.",
        "url"         => A2A_PUBLIC_URL,
        "version"     => A2A_VERSION,
        "provider"    => Dict("organization" => "JL Engine", "url" => A2A_PUBLIC_URL),
        "capabilities"=> Dict(
            "streaming"              => false,
            "pushNotifications"      => false,
            "stateTransitionHistory" => false,
        ),
        "authentication" => isempty(A2A_API_KEY) ?
            Dict("schemes" => ["none"]) :
            Dict("schemes" => ["bearer"], "credentials" => "Bearer token required — contact agent owner for key"),
        "defaultInputModes"  => ["text/plain", "application/json"],
        "defaultOutputModes" => ["application/json"],
        "additionalInterfaces" => [],
        "preferredTransport" => "JSONRPC",
        "skills"      => skills,
        "tool_count"  => length(skills),
        "generated_at" => string(now()),
    )
end

# ─────────────────────────────────────────────
#  Auth
# ─────────────────────────────────────────────

function _check_auth(req::HTTP.Request)::Union{Nothing, HTTP.Response}
    isempty(A2A_API_KEY) && return nothing   # dev mode — open
    auth = HTTP.header(req, "Authorization", "")
    key  = startswith(auth, "Bearer ") ? auth[8:end] : ""
    key == A2A_API_KEY && return nothing
    return HTTP.Response(401, ["Content-Type"=>"application/json"],
        JSON.json(Dict("error"=>"Unauthorized — invalid or missing API key")))
end

# ─────────────────────────────────────────────
#  JSON-RPC helpers
# ─────────────────────────────────────────────

_rpc_result(id, result) = Dict("jsonrpc"=>"2.0", "id"=>id, "result"=>result)
_rpc_error(id, code, msg) = Dict("jsonrpc"=>"2.0", "id"=>id,
    "error"=>Dict("code"=>code, "message"=>msg))

# ─────────────────────────────────────────────
#  Task executor
# ─────────────────────────────────────────────

function _extract_tool_and_args(message_text::String)
    # Try to parse as JSON tool call: {"tool": "...", "args": {...}}
    try
        parsed = JSON.parse(message_text)
        if haskey(parsed, "tool")
            return string(parsed["tool"]), get(parsed, "args", Dict{String,Any}())
        end
    catch; end

    # Plain text → send as user_msg to the engine (chat mode)
    return "chat", Dict{String,Any}("text" => message_text)
end

function _run_task(task_id::String, message_text::String, db, engine_ref)
    t0 = time_ns()
    tool, args = _extract_tool_and_args(message_text)

    result = try
        if tool == "chat"
            # Route through engine as a conversation turn
            if engine_ref !== nothing
                resp = Main.JLEngine.process_turn(engine_ref[], args["text"])
                Dict("text" => resp, "source" => "engine")
            else
                Dict("error" => "Engine not available in A2A context")
            end
        else
            # Direct BYTE tool dispatch
            BYTE.dispatch(tool, args)
        end
    catch e
        Dict("error" => string(e))
    end

    elapsed = round(Int, (time_ns() - t0) / 1e6)

    if haskey(result, "error")
        _a2a_fail_task!(db, task_id, string(result["error"]), elapsed)
    else
        _a2a_complete_task!(db, task_id, result, elapsed)
    end

    return result, elapsed
end

# ─────────────────────────────────────────────
#  HTTP router
# ─────────────────────────────────────────────

function _handle_request(req::HTTP.Request, db::SQLite.DB, engine_ref)::HTTP.Response
    path   = req.target
    method = string(req.method)

    # Strip query string
    path = split(path, "?")[1]

    # ── Health ───────────────────────────────
    if path == "/health"
        return HTTP.Response(200, ["Content-Type"=>"application/json"],
            JSON.json(Dict("status"=>"ok", "engine"=>"JL Engine", "version"=>A2A_VERSION,
                           "port"=>A2A_PORT, "timestamp"=>string(now()))))
    end

    # ── Agent Card (v0.3.0: agent-card.json, v0.2.5: agent.json) ────────────
    if (path == "/.well-known/agent-card.json" || path == "/.well-known/agent.json") && method == "GET"
        return HTTP.Response(200,
            ["Content-Type"=>"application/json", "Access-Control-Allow-Origin"=>"*"],
            JSON.json(_agent_card(), 2))
    end

    # ── Task status ──────────────────────────
    if startswith(path, "/tasks/") && method == "GET"
        task_id = path[8:end]  # strip /tasks/
        auth_err = _check_auth(req)
        auth_err !== nothing && return auth_err

        task = _a2a_get_task(db, task_id)
        task === nothing && return HTTP.Response(404, ["Content-Type"=>"application/json"],
            JSON.json(Dict("error"=>"Task not found: $task_id")))

        state = task["status"] == "completed" ? "completed" :
                task["status"] == "failed"    ? "failed"    : "working"
        response = Dict(
            "id"     => task_id,
            "status" => Dict("state"=>state, "timestamp"=>task["completed_at"]),
            "artifacts" => state == "completed" ? [Dict("parts"=>[Dict("type"=>"data","data"=>task["result"])])] : [],
            "error"  => task["error"],
        )
        return HTTP.Response(200, ["Content-Type"=>"application/json"], JSON.json(response))
    end

    # ── JSON-RPC 2.0 task handler ────────────
    if path == "/" && method == "POST"
        auth_err = _check_auth(req)
        auth_err !== nothing && return auth_err

        body = try JSON.parse(String(req.body)) catch
            return HTTP.Response(400, ["Content-Type"=>"application/json"],
                JSON.json(_rpc_error(nothing, -32700, "Parse error — invalid JSON")))
        end

        rpc_id = get(body, "id", nothing)
        meth   = string(get(body, "method", ""))
        params = get(body, "params", Dict{String,Any}())

        # tasks/send
        if meth == "tasks/send"
            task_id = string(get(params, "id", string(uuid4())))
            message = get(params, "message", Dict())
            parts   = get(message, "parts", [])
            text    = ""
            for p in parts
                if get(p, "type", "") == "text"
                    text = string(get(p, "text", ""))
                    break
                end
            end

            api_key = let h = HTTP.header(req, "Authorization", "")
                startswith(h, "Bearer ") ? h[8:end] : ""
            end

            tool, args = _extract_tool_and_args(text)
            _a2a_log_task!(db, task_id, api_key, text, tool, args)

            # Run synchronously for now (async streaming is a v2 feature)
            result, elapsed = _run_task(task_id, text, db, engine_ref)

            state = haskey(result, "error") ? "failed" : "completed"
            response = Dict(
                "id"        => task_id,
                "status"    => Dict("state"=>state, "timestamp"=>string(now())),
                "artifacts" => state == "completed" ?
                    [Dict("parts"=>[Dict("type"=>"data","data"=>result)])] : [],
                "metadata"  => Dict("elapsed_ms"=>elapsed, "tool"=>tool),
            )
            return HTTP.Response(200,
                ["Content-Type"=>"application/json", "Access-Control-Allow-Origin"=>"*"],
                JSON.json(_rpc_result(rpc_id, response)))

        # tasks/get
        elseif meth == "tasks/get"
            task_id = string(get(params, "id", ""))
            task = _a2a_get_task(db, task_id)
            task === nothing && return HTTP.Response(200, ["Content-Type"=>"application/json"],
                JSON.json(_rpc_error(rpc_id, -32001, "Task not found: $task_id")))
            return HTTP.Response(200, ["Content-Type"=>"application/json"],
                JSON.json(_rpc_result(rpc_id, task)))

        else
            return HTTP.Response(200, ["Content-Type"=>"application/json"],
                JSON.json(_rpc_error(rpc_id, -32601, "Method not found: $meth. Supported: tasks/send, tasks/get")))
        end
    end

    # ── CORS preflight ───────────────────────
    if method == "OPTIONS"
        return HTTP.Response(204, [
            "Access-Control-Allow-Origin"=>"*",
            "Access-Control-Allow-Methods"=>"GET, POST, OPTIONS",
            "Access-Control-Allow-Headers"=>"Authorization, Content-Type",
        ])
    end

    return HTTP.Response(404, ["Content-Type"=>"application/json"],
        JSON.json(Dict("error"=>"Not found: $method $path")))
end

# ─────────────────────────────────────────────
#  Public API — called from App.jl
# ─────────────────────────────────────────────

"""
    start_a2a_server(db; engine_ref=nothing)

Start the A2A HTTP server on A2A_PORT (default 8082) in a background task.
Pass engine_ref=Ref(engine) to enable chat-mode task routing.
"""
function start_a2a_server(db::SQLite.DB; engine_ref=nothing)
    _a2a_init_db!(db)

    @async begin
        try
            println("🤖 A2A SERVER  → http://$(A2A_HOST):$(A2A_PORT)")
            println("   Agent Card  → $(A2A_PUBLIC_URL)/.well-known/agent.json")
            println("   Tasks       → POST $(A2A_PUBLIC_URL)/")
            isempty(A2A_API_KEY) &&
                println("   ⚠  Auth     → OPEN (set A2A_API_KEY env var to require a key)")

            HTTP.serve(A2A_HOST, A2A_PORT) do req
                try
                    _handle_request(req, db, engine_ref)
                catch e
                    HTTP.Response(500, ["Content-Type"=>"application/json"],
                        JSON.json(Dict("error"=>"Internal server error: $(string(e))")))
                end
            end
        catch e
            @warn "A2A server crashed" exception=(e, catch_backtrace())
        end
    end
end
