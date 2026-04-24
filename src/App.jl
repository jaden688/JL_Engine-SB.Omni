using Dates
using JSON
using PythonCall
using SQLite

# ── Load .env file into ENV (before anything else reads keys) ─────────────────
let env_path = joinpath(@__DIR__, "..", ".env")
    if isfile(env_path)
        for line in eachline(env_path)
            line = strip(line)
            isempty(line) || startswith(line, "#") && continue
            m = match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if m !== nothing
                key, val = string(m[1]), strip(string(m[2]), ['"', '\''])
                # Don't overwrite keys already set in the real environment
                isempty(get(ENV, key, "")) && (ENV[key] = val)
            end
        end
        @info "Loaded .env"
    end
end

include(joinpath(@__DIR__, "..", "BYTE", "src", "BYTE.jl"))
include(joinpath(@__DIR__, "..", "a2a_server.jl"))
include(joinpath(@__DIR__, "Autopilot.jl"))

# DataFrames is used by Autopilot for query results — BYTE already depends on it
import DataFrames

const DEFAULT_HOST = "127.0.0.1"
const DEFAULT_PORT = 8081

function _looks_true(value::AbstractString)
    normalized = lowercase(strip(value))
    return !(normalized in ("", "0", "false", "no", "off"))
end

function _runtime_candidates()
    env_root = strip(get(ENV, "SPARKBYTE_ROOT", ""))
    candidates = String[]
    !isempty(env_root) && push!(candidates, env_root)
    push!(candidates, normpath(joinpath(Sys.BINDIR, "..")))
    push!(candidates, normpath(joinpath(@__DIR__, "..")))
    return unique(abspath.(candidates))
end

function runtime_root()
    for candidate in _runtime_candidates()
        isfile(joinpath(candidate, "data", "agents", "Agents.mpf.json")) && return candidate
    end
    error("Could not locate SparkByte runtime root. Set SPARKBYTE_ROOT to a folder containing data/agents/Agents.mpf.json.")
end

function state_root(root::String=runtime_root())
    configured = strip(get(ENV, "SPARKBYTE_STATE_DIR", ""))
    if !isempty(configured) && Sys.islinux() && occursin(r"^[A-Za-z]:[\\/]"i, configured)
        configured = isdir("/app") ? "/app/runtime" : ""
    end
    dir = isempty(configured) ? root : abspath(configured)
    mkpath(dir)
    return dir
end

function _load_env!(root::String)
    env_path = joinpath(root, ".env")
    isfile(env_path) || return
    for raw_line in eachline(env_path)
        line = strip(raw_line)
        isempty(line) && continue
        startswith(line, "#") && continue
        match_obj = match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        match_obj === nothing && continue
        ENV[match_obj[1]] = strip(match_obj[2], ['"', '\''])
    end
end

function _open_memory_db(root::String)
    db = SQLite.DB(joinpath(state_root(root), "sparkbyte_memory.db"))
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS memory (id INTEGER PRIMARY KEY, timestamp TEXT, tag TEXT, key TEXT, content TEXT)")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS tools (
        id INTEGER PRIMARY KEY, name TEXT UNIQUE, source TEXT, description TEXT,
        parameters TEXT, is_dynamic INTEGER DEFAULT 0, forged_at TEXT, last_used TEXT, call_count INTEGER DEFAULT 0)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS thoughts (
        id INTEGER PRIMARY KEY, timestamp TEXT, jl_agent TEXT DEFAULT 'SparkByte',
        context TEXT, thought TEXT, mood TEXT, gait TEXT,
        type TEXT DEFAULT 'diary', model TEXT DEFAULT '')""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS knowledge (
        id INTEGER PRIMARY KEY, domain TEXT, topic TEXT, content TEXT, source TEXT, learned TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS agents (
        id INTEGER PRIMARY KEY, name TEXT UNIQUE, description TEXT, agent_profile TEXT,
        tone TEXT, boot_prompt TEXT, active INTEGER DEFAULT 0, last_used TEXT)""")
    try
        cols = DataFrame(SQLite.DBInterface.execute(db, "PRAGMA table_info(agents)"))
        has_profile = any(string(getproperty(r, :name)) == "agent_profile" for r in eachrow(cols))
        has_profile || SQLite.execute(db, "ALTER TABLE agents ADD COLUMN agent_profile TEXT")
    catch e
        @warn "Agent table migration check failed" exception=(e, catch_backtrace())
    end
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS behavior_states (
        id INTEGER PRIMARY KEY, state_id TEXT UNIQUE, name TEXT, intensity INTEGER, control INTEGER,
        expressiveness REAL, pacing TEXT, tone_bias TEXT, memory_strictness TEXT, trigger_conditions TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY, session_id TEXT, started_at TEXT, ended_at TEXT,
        os TEXT, julia_ver TEXT, events INTEGER DEFAULT 0, notes TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS web_cache (
        id INTEGER PRIMARY KEY, url TEXT, fetched_at TEXT, content TEXT, summary TEXT, tags TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS tool_usage_log (
        id INTEGER PRIMARY KEY, timestamp TEXT, tool_name TEXT, args_json TEXT,
        result_json TEXT, duration_ms INTEGER, jl_agent TEXT, session_id TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS telemetry (
        id INTEGER PRIMARY KEY, timestamp TEXT, session_id TEXT, event TEXT,
        turn_number INTEGER DEFAULT 0, model TEXT DEFAULT '', jl_agent TEXT DEFAULT '',
        data_json TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS turn_snapshots (
        id INTEGER PRIMARY KEY,
        timestamp TEXT,
        session_id TEXT,
        turn_number INTEGER,
        jl_agent TEXT,
        model TEXT,
        gait TEXT,
        rhythm_mode TEXT,
        rhythm_momentum REAL,
        aperture_mode TEXT,
        aperture_temp REAL,
        aperture_top_p REAL,
        behavior_state TEXT,
        behavior_expressiveness REAL,
        behavior_pacing TEXT,
        behavior_tone TEXT,
        drift_pressure REAL,
        drift_temp_delta REAL,
        drift_action_level TEXT,
        advisory_bias TEXT,
        advisory_emotional_drift TEXT,
        advisory_msg TEXT,
        user_msg_len INTEGER,
        reply_len INTEGER,
        elapsed_ms INTEGER)""")
    _a2a_init_db!(db)
    return db
end

function _start_browser_context()
    println("👁️  Initializing Web Eyes...")
    sync_playwright = pyimport("playwright.sync_api").sync_playwright
    pw_instance = sync_playwright().__enter__()

    # Persistent profile so cookies / captcha solves / login state survive restarts.
    # Realistic UA + viewport + locale to defeat trivial bot fingerprinting.
    # Override with SPARKBYTE_CHROME_PROFILE env var. Nuke the folder to reset.
    user_data_dir = get(ENV, "SPARKBYTE_CHROME_PROFILE",
        joinpath(homedir(), ".sparkbyte", "chromium_profile"))
    try
        mkpath(user_data_dir)
    catch e
        @warn "Failed to create SparkByte Chrome profile directory" path=user_data_dir exception=(e, catch_backtrace())
    end

    ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " *
         "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    launch_args = pylist([
        "--disable-blink-features=AutomationControlled",
        "--no-default-browser-check",
        "--no-first-run",
        "--disable-features=IsolateOrigins,site-per-process",
    ])

    browser_context = pw_instance.chromium.launch_persistent_context(
        user_data_dir,
        headless=true,
        user_agent=ua,
        locale="en-US",
        timezone_id="America/New_York",
        viewport=pydict(Dict("width" => 1920, "height" => 1080)),
        args=launch_args,
    )

    # Stealth: strip webdriver flag + common automation tells before any page load.
    stealth_js = """
    Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
    Object.defineProperty(navigator, 'languages', {get: () => ['en-US','en']});
    Object.defineProperty(navigator, 'plugins', {get: () => [1,2,3,4,5]});
    window.chrome = window.chrome || { runtime: {} };
    """
    try
        browser_context.add_init_script(stealth_js)
    catch e
        @warn "stealth init_script failed" exception=e
    end

    # browser handle kept as the context itself so shutdown_cleanly! can close it.
    browser = browser_context
    return (; pw_instance, browser, browser_context)
end

# Module-level state for clean shutdown. Set on boot, consumed by shutdown_cleanly!.
const _browser_stack_ref = Ref{Any}(nothing)
const _cleanup_done = Ref(false)
const _session_shutdown_done = Ref(false)
const _julian_service_ref = Ref{Any}(nothing)
const _julian_service_owned = Ref(false)
const JULIAN_META_MORPH_HOST = "127.0.0.1"
const JULIAN_META_MORPH_PORT = 8765

"""
    shutdown_cleanly!()

Close Playwright browser + pw_instance while Python is still healthy.
Idempotent — safe to call multiple times. Call this BEFORE `exit(0)` to avoid
the PythonCall segfault that happens when atexit tries to touch Python objects
mid-teardown. atexit blocks also call this as a safety net.
"""
function shutdown_cleanly!()
    _cleanup_done[] && return
    _cleanup_done[] = true
    _stop_julian_service!()
    bs = _browser_stack_ref[]
    bs === nothing && return
    # IMPORTANT: do NOT use @warn or format exception backtraces here.
    # Python objects in the exception payload cause GC walks across task
    # boundaries during exit(), which segfaults. Plain println only.
    try
        bs.browser.close()
    catch
        println(stderr, "[shutdown_cleanly!] browser.close() raised (ignored)")
    end
    try
        bs.pw_instance.__exit__(nothing, nothing, nothing)
    catch
        println(stderr, "[shutdown_cleanly!] pw_instance.__exit__ raised (ignored)")
    end
end

function _julian_service_healthy()::Bool
    status, _ = BYTE._probe_http_status("http://$(JULIAN_META_MORPH_HOST):$(JULIAN_META_MORPH_PORT)/health")
    return status == 200
end

function _stop_julian_service!()
    state = _julian_service_ref[]
    _julian_service_ref[] = nothing
    owned = _julian_service_owned[]
    _julian_service_owned[] = false
    (state === nothing || !owned) && return
    proc = getproperty(state, :proc)
    try
        kill(proc)
    catch
    end
    try
        wait(proc)
    catch
    end
end

function _start_julian_service!(root::String)
    _julian_service_healthy() && return false

    jr = strip(get(ENV, "JULIAN_ROOT", ""))
    if isempty(jr) || !isdir(jr)
        @warn "Julian MetaMorph service skipped — JULIAN_ROOT not found" julian_root=jr
        return false
    end

    py = strip(get(ENV, "PYTHON", "python"))
    out_log = open(joinpath(state_root(root), "julian_metamorph.out.log"), "a")
    err_log = open(joinpath(state_root(root), "julian_metamorph.err.log"), "a")
    proc = nothing
    try
        proc = cd(jr) do
            withenv("PYTHONPATH" => "src") do
                run(pipeline(
                    Cmd([py, "-m", "julian_metamorph.cli", "serve",
                        "--host", JULIAN_META_MORPH_HOST,
                        "--port", string(JULIAN_META_MORPH_PORT)]),
                    stdout=out_log,
                    stderr=err_log,
                ); wait=false)
            end
        end

        for _ in 1:20
            _julian_service_healthy() && break
            sleep(0.5)
        end

        if _julian_service_healthy()
            _julian_service_ref[] = (; proc=proc, root=jr)
            _julian_service_owned[] = true
            @info "Julian MetaMorph service started" host=JULIAN_META_MORPH_HOST port=JULIAN_META_MORPH_PORT
            return true
        end

        @warn "Julian MetaMorph service failed to become ready" root=jr
        try
            kill(proc)
        catch
        end
        try
            wait(proc)
        catch
        end
        return false
    catch e
        @warn "Failed to launch Julian MetaMorph service" exception=(e, catch_backtrace())
        return false
    finally
        close(out_log)
        close(err_log)
    end
end

function _seed_self_context!(db::SQLite.DB, root::String)
    println("🧠 Seeding engine state into SQLite...")
    tree = String[]
    for (dirpath, dirs, files) in walkdir(root)
        filter!(d -> d ∉ [".git", "__pycache__", ".vscode", "_repo_inspect", "bin", "lib", "share"], dirs)
        rel = relpath(dirpath, root)
        for file_name in files
            any(endswith(file_name, ext) for ext in (".jl", ".json", ".toml", ".py", ".md", ".txt", ".html")) || continue
            push!(tree, joinpath(rel, file_name))
        end
    end
    SQLite.execute(db, "DELETE FROM memory WHERE tag = 'self_tree'")
    SQLite.execute(db, "INSERT INTO memory (timestamp, tag, key, content) VALUES (?, ?, ?, ?)",
        (string(Dates.now()), "self_tree", "project_files", join(tree, "\n")))

    key_files = [
        "sparkbyte.jl",
        "BYTE/src/BYTE.jl",
        "BYTE/src/Tools.jl",
        "BYTE/src/Schema.jl",
        "src/JLEngine.jl",
        "src/App.jl",
        "src/JLEngine/Core.jl",
        "src/JLEngine/Types.jl",
        "data/agents/Agents.mpf.json",
    ]
    SQLite.execute(db, "DELETE FROM memory WHERE tag = 'self_src'")
    for path in key_files
        full = joinpath(root, path)
        isfile(full) || continue
        content = read(full, String)
        SQLite.execute(db, "INSERT INTO memory (timestamp, tag, key, content) VALUES (?, ?, ?, ?)",
            (string(Dates.now()), "self_src", path, first(content, 8000)))
    end

    bs_path = joinpath(root, "data", "behavior_states.json")
    if isfile(bs_path)
        bs_data = JSON.parsefile(bs_path)
        SQLite.execute(db, "DELETE FROM behavior_states")
        for row in get(bs_data, "states", [])
            for cell in row
                coords = split(get(cell, "id", "0,0"), ",")
                SQLite.execute(db, """INSERT OR REPLACE INTO behavior_states
                    (state_id, name, intensity, control, expressiveness, pacing, tone_bias, memory_strictness, trigger_conditions)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""", (
                    get(cell, "id", ""),
                    get(cell, "name", ""),
                    parse(Int, coords[1]),
                    parse(Int, coords[2]),
                    get(cell, "expressiveness", 0.0),
                    get(cell, "pacing", ""),
                    get(cell, "tone_bias", ""),
                    get(cell, "memory_strictness", ""),
                    JSON.json(get(bs_data, "trigger_mappings", Dict()))
                ))
            end
        end
        println("  ✅ Behavior states: $(length(get(bs_data, "states", [])) * 4) cells indexed")
    end

    agents_dir = joinpath(root, "data", "agents")
    mpf_path = joinpath(agents_dir, "Agents.mpf.json")
    SQLite.execute(db, "DELETE FROM agents")
    if isfile(mpf_path)
        registry = JSON.parsefile(mpf_path)
        for (agent_name, agent_meta) in registry
            agent_file = joinpath(agents_dir, get(agent_meta, "agent_file", ""))
            isfile(agent_file) || continue
            fat = JSON.parsefile(agent_file)
            identity = get(fat, "identity", Dict())
            boot = ""
            if haskey(fat, "llm_profiles")
                generic = get(fat["llm_profiles"], "generic_llm", Dict())
                boot = get(generic, "boot_prompt", "")
            end
            style_profile_key = string("person", "ality_matrix")
            agent_profile = JSON.json(get(fat, style_profile_key, get(fat, "voice", Dict())))
            tone = get(get(fat, "voice", Dict()), "tone", get(identity, "archetype", ""))
            desc = get(identity, "description", "")
            SQLite.execute(db, """INSERT OR REPLACE INTO agents
                (name, description, agent_profile, tone, boot_prompt, active, last_used)
                VALUES (?, ?, ?, ?, ?, ?, ?)""", (
                agent_name,
                desc,
                first(agent_profile, 2000),
                tone,
                first(boot, 4000),
                agent_name == "SparkByte" ? 1 : 0,
                string(Dates.now())
            ))
        end
        println("  ✅ JL-agents: $(length(registry)) agents indexed")
    end

    SQLite.execute(db, "DELETE FROM knowledge WHERE domain = 'tool_schema'")
    all_tool_decls = BYTE.TOOLS_SCHEMA[1]["function_declarations"]
    for tool_decl in all_tool_decls
        SQLite.execute(db, """INSERT INTO knowledge (domain, topic, content, source, learned)
            VALUES (?, ?, ?, ?, ?)""", (
            "tool_schema",
            get(tool_decl, "name", ""),
            JSON.json(tool_decl),
            "BYTE/src/Schema.jl",
            string(Dates.now())
        ))
    end
    println("  ✅ Tool schemas: $(length(all_tool_decls)) tools indexed")

    fw_path = joinpath(root, "data", "JLframe_Engine_Framework.json")
    if isfile(fw_path)
        fw = JSON.parsefile(fw_path)
        SQLite.execute(db, "DELETE FROM knowledge WHERE domain = 'engine_framework'")
        for (section, value) in fw
            (value isa Dict || value isa Vector) || continue
            SQLite.execute(db, """INSERT INTO knowledge (domain, topic, content, source, learned)
                VALUES (?, ?, ?, ?, ?)""", (
                "engine_framework",
                string(section),
                first(JSON.json(value), 3000),
                "data/JLframe_Engine_Framework.json",
                string(Dates.now())
            ))
        end
        println("  ✅ Engine framework: $(length(fw)) sections indexed")
    end

    SQLite.execute(db, "DELETE FROM knowledge WHERE domain = 'engine_capabilities'")
    engine_caps = [
        ("gait_levels",   "walk / trot / sprint / idle — controls how aggressively the engine responds. Walk=calm, Sprint=urgent."),
        ("rhythm_modes",  "flip / flop / trot — pacing of response generation. Flip=reactive, Flop=deliberate, Trot=balanced."),
        ("aperture_modes","OPEN / FOCUSED / TIGHT — emotional temperature range. OPEN=high temp/creative, TIGHT=precise/low temp."),
        ("drift_pressure","0.0–1.0 pressure score. High drift = user is pushing hard, agent should adapt or resist."),
        ("behavior_grid", "5 intensity rows (0=Dormant→4=Surge) × 4 control cols (0=Disciplined→3=Chaotic) = 20 named states."),
        ("advisory_flags","gating_bias / emotional_drift / msg — engine advice to LLM on how to shape its reply this turn."),
        ("forge_new_tool","Evals Julia code directly into live BYTE module. Use to add persistent capabilities. Persists across reboots."),
        ("bluetooth_devices","Lists Bluetooth adapter state and known devices using the host operating system."),
        ("send_sms",      "Sends SMS through Twilio when TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_FROM_NUMBER are configured."),
        ("docker_state_dir","SPARKBYTE_STATE_DIR relocates SQLite, telemetry, health logs, and forged-tool state for clean Docker volume mounts."),
        ("providers",     "gemini / xai / xai_responses / openai / ollama / cerebras — all routed through same agentic loop with full tool access."),
        ("jl_agent_switch","Use /gear JL_AGENT_NAME in chat or set_agent!(engine, name) to switch the active jl-agent. Reloads fat JSON, resets gait/rhythm/stability."),
    ]
    for (topic, content) in engine_caps
        SQLite.execute(db, """INSERT INTO knowledge (domain, topic, content, source, learned)
            VALUES (?, ?, ?, ?, ?)""", (
            "engine_capabilities",
            topic,
            content,
            "src/App.jl:seed",
            string(Dates.now())
        ))
    end
    println("  ✅ Engine capabilities: $(length(engine_caps)) entries indexed")

    for index_sql in [
        "CREATE INDEX IF NOT EXISTS idx_memory_tag ON memory(tag)",
        "CREATE INDEX IF NOT EXISTS idx_knowledge_domain ON knowledge(domain)",
        "CREATE INDEX IF NOT EXISTS idx_knowledge_topic ON knowledge(domain, topic)",
        "CREATE INDEX IF NOT EXISTS idx_behavior_name ON behavior_states(name)",
        "CREATE INDEX IF NOT EXISTS idx_agents_name ON agents(name)",
        "CREATE INDEX IF NOT EXISTS idx_telemetry_event ON telemetry(event)",
        "CREATE INDEX IF NOT EXISTS idx_telemetry_jl_agent ON telemetry(jl_agent)",
        "CREATE INDEX IF NOT EXISTS idx_thoughts_type ON thoughts(type)",
        "CREATE INDEX IF NOT EXISTS idx_thoughts_jl_agent ON thoughts(jl_agent)",
        "CREATE INDEX IF NOT EXISTS idx_tool_usage_name ON tool_usage_log(tool_name)",
    ]
        SQLite.execute(db, index_sql)
    end
    println("  ✅ SQLite indexes created")
    println("✅ Self-context loaded: $(length(tree)) files, $(length(key_files)) sources, engine state fully indexed.")
end

function _build_engine(root::String)
    println("⚙️  Booting JL Engine Core...")
    return JLEngineCore(EngineConfig(
        root_dir             = joinpath(root, "data"),
        master_file          = "JLframe_Engine_Framework.json",
        behavior_states_file = "behavior_states.json",
        mpf_registry_file    = "agents/Agents.mpf.json",
        personas_dir         = "agents",
        default_persona_name = "SparkByte",
    ))
end

function _env_port()
    raw = get(ENV, "SPARKBYTE_PORT", string(DEFAULT_PORT))
    return something(tryparse(Int, raw), DEFAULT_PORT)
end

"""
    _sync_julian_env!(root)

Join SparkByte with JulianMetaMorph in the same repo: set `JULIAN_ROOT` and `JULIAN_DB`
when unset so `metamorph grab_from_julian` and MCP `search_julian_quarry` hit the same quarry.
Override anytime with env vars.
"""
function _sync_julian_env!(root::String)
    embedded = joinpath(root, "JulianMetaMorph", "JulianMetaMorph")
    if isempty(strip(get(ENV, "JULIAN_ROOT", ""))) && isdir(embedded)
        ENV["JULIAN_ROOT"] = embedded
    end
    jr = strip(get(ENV, "JULIAN_ROOT", ""))
    if !isempty(jr) && isempty(strip(get(ENV, "JULIAN_DB", "")))
        db = joinpath(jr, "data", "quarry.db")
        isfile(db) && (ENV["JULIAN_DB"] = db)
    end
    return
end

function _normalize_agents_registry_paths!(root::String)
    registry_path = joinpath(root, "data", "agents", "Agents.mpf.json")
    isfile(registry_path) || return
    registry = JSON.parsefile(registry_path)
    touched = false
    for (_, meta_any) in pairs(registry)
        meta_any isa AbstractDict || continue
        meta = meta_any
        old_path = string(get(meta, "agent_file", ""))
        isempty(old_path) && continue
        if startswith(old_path, "../agents/")
            filename = basename(old_path)
            new_rel = "../agents/$filename"
            meta["agent_file"] = new_rel
            touched = true
        end
    end
    touched || return
    open(registry_path, "w") do io
        JSON.print(io, registry, 2)
    end
    @info "Normalized agent registry paths from legacy data/agents to data/agents"
end

function _upsert_agents_registry_entry!(root::String, jl_agent_name::String, agent_file_name::String)
    registry_path = joinpath(root, "data", "agents", "Agents.mpf.json")
    isfile(registry_path) || return
    registry = JSON.parsefile(registry_path)
    entry = get(registry, jl_agent_name, Dict{String,Any}())
    entry["agent_file"] = "../agents/$(agent_file_name)"
    haskey(entry, "default_memory_mode") || (entry["default_memory_mode"] = "HYBRID")
    haskey(entry, "default_backend_id") || (entry["default_backend_id"] = "google-gemini")
    haskey(entry, "drive_type") || (entry["drive_type"] = nothing)
    haskey(entry, "tags") || (entry["tags"] = ["imported", "card-cruncher"])
    registry[jl_agent_name] = entry
    open(registry_path, "w") do io
        JSON.print(io, registry, 2)
    end
end

function _bridge_legacy_agent_cards!(root::String)
    legacy_dir = joinpath(root, "data", "agents")
    agents_dir = joinpath(root, "data", "agents")
    isdir(legacy_dir) || return
    mkpath(agents_dir)

    copied_profiles = 0
    converted_cards = 0
    cruncher_loaded = false

    # Treat data/agents as a legacy card inbox + profile source.
    for entry in readdir(legacy_dir; join=true)
        isfile(entry) || continue
        base = basename(entry)
        if lowercase(base) in ("agents.mpf.json", "jl_agents.mpf.json", "agents.mpf.json")
            continue
        end
        ext = lowercase(splitext(base)[2])

        if ext == ".json"
            parsed = try
                JSON.parsefile(entry)
            catch
                nothing
            end

            if parsed isa AbstractDict &&
               haskey(parsed, "identity") &&
               haskey(parsed, "engine_alignment")
                out_path = joinpath(agents_dir, base)
                src_mtime = stat(entry).mtime
                dst_mtime = isfile(out_path) ? stat(out_path).mtime : DateTime(0)
                if !isfile(out_path) || src_mtime > dst_mtime
                    cp(entry, out_path; force=true)
                    copied_profiles += 1
                end
                identity = get(parsed, "identity", Dict{String,Any}())
                jl_agent_name = string(get(identity, "name", replace(base, r"_Full\.json$" => "")))
                _upsert_agents_registry_entry!(root, jl_agent_name, basename(out_path))
                continue
            end
        end

        if ext in (".png", ".json", ".txt")
            try
                if !cruncher_loaded
                    include(joinpath(root, "card_cruncher.jl"))
                    cruncher_loaded = true
                end
                cc_fn = getfield(@__MODULE__, :crunch_card)
                result_path = Base.invokelatest(cc_fn, entry; engine_root=root, dry_run=false)
                jl_agent_name = replace(basename(String(result_path)), r"_Full\.json$" => "")
                _upsert_agents_registry_entry!(root, jl_agent_name, basename(String(result_path)))
                converted_cards += 1
            catch e
                @warn "Legacy card import failed; leaving source file untouched" file=entry exception=(e, catch_backtrace())
            end
        end
    end

    _normalize_agents_registry_paths!(root)

    if copied_profiles > 0 || converted_cards > 0
        @info "Bridged legacy data/agents into data/agents" copied_profiles converted_cards
    end
end

const JULIAN_DEFAULT_INTERVAL_SECONDS = 3600

"""
Background loop: Julian runs `curiosity-hunt` on an interval.
Default: every $(JULIAN_DEFAULT_INTERVAL_SECONDS)s (1 hour). Override with `JULIAN_AUTONOMOUS_SECONDS`.
Set to -1 to explicitly disable (not recommended).
"""
function _start_julian_autonomous_loop!(root::String)
    raw = strip(get(ENV, "JULIAN_AUTONOMOUS_SECONDS", ""))
    sec = isempty(raw) ? JULIAN_DEFAULT_INTERVAL_SECONDS : tryparse(Int, raw)
    if sec === nothing || sec < 0
        @info "Julian autonomous curiosity DISABLED (JULIAN_AUTONOMOUS_SECONDS=$raw)"
        return
    end
    sec = max(sec, 120)  # floor at 2 minutes to avoid hammering GitHub
    jr = strip(get(ENV, "JULIAN_ROOT", ""))
    if isempty(jr) || !isdir(jr)
        @warn "Julian autonomous loop skipped — JULIAN_ROOT not found" julian_root=jr
        return
    end
    # First hunt is delayed so boot doesn't race against GitHub's rate limit
    # right when the user is most likely to be poking around the UI.
    initial_delay = let raw = strip(get(ENV, "JULIAN_AUTONOMOUS_INITIAL_DELAY", ""))
        d = isempty(raw) ? nothing : tryparse(Int, raw)
        d === nothing ? max(sec, 300) : max(d, 0)
    end
    println("🔁 Julian autonomous curiosity → first hunt in $(initial_delay)s, then every $(sec)s")
    @async begin
        sleep(initial_delay)
        while true
            try
                r = BYTE.run_julian_curiosity_hunt!(root; broadcast_result=true)
                if get(r, "ok", false)
                    data = get(r, "data", Dict())
                    @info "Julian hunt completed" task=get(data, "picked_task", "?") hits=get(data, "hit_count", 0)
                else
                    @warn "Julian autonomous hunt did not complete" result=r
                end
            catch e
                @warn "Julian autonomous loop error" exception=(e, catch_backtrace())
            end
            sleep(sec)
        end
    end
    return
end

function app_main(; host::String=get(ENV, "SPARKBYTE_HOST", DEFAULT_HOST),
                    port::Int=_env_port(),
                    launch_browser::Bool=_looks_true(get(ENV, "SPARKBYTE_LAUNCH_BROWSER", "1")),
                    root::String=runtime_root())
    _load_env!(root)
    _sync_julian_env!(root)
    _bridge_legacy_agent_cards!(root)

    db = _open_memory_db(root)
    browser_stack = _start_browser_context()
    _browser_stack_ref[] = browser_stack
    _cleanup_done[] = false
    BYTE.init(db, browser_stack.browser_context, root)
    try
        _seed_self_context!(db, root)
    catch e
        @warn "Self-context seed skipped (DB may still be warming up)" exception=(e, catch_backtrace())
    end
    engine = _build_engine(root)
    if _looks_true(get(ENV, "JULIAN_MANAGED_SERVICE", "1"))
        try
            _start_julian_service!(root)
        catch e
            @warn "Julian managed service failed to start — SparkByte will continue without it" exception=(e, catch_backtrace())
        end
    end

    # Sync BYTE's model/provider state into JLEngine Backends on first boot
    try
        JLEngine.sync_from_byte!()
    catch e
        @warn "Initial sync_from_byte! failed — backends fall back to env-detected defaults" exception=(e, catch_backtrace())
    end

    _start_julian_autonomous_loop!(root)

    atexit() do
        # H-12: guard against double-invocation. atexit handlers run LIFO; if
        # shutdown_cleanly! already ran this sequence, a repeat pass at exit
        # touches already-closed state and emits swallowed errors that mask
        # real teardown issues.
        _session_shutdown_done[] && return
        _session_shutdown_done[] = true
        try
            _autopilot_stop!()
        catch e
            @warn "Failed to stop autopilot cleanly during shutdown" exception=(e, catch_backtrace())
        end
        try
            BYTE._db_end_session(BYTE._session_id)
        catch err
            @warn "Failed to close SparkByte session cleanly" exception=(err, catch_backtrace())
        end
    end
    # Safety-net atexit: only runs Python cleanup if shutdown_cleanly! wasn't
    # already called explicitly. Guarded by Py_IsInitialized to avoid segfault
    # if the runtime has already torn down. For graceful restart/reset, callers
    # should invoke App.shutdown_cleanly!() BEFORE exit(0) — that's the safe path.
    atexit() do
        _cleanup_done[] && return
        try
            py_alive = ccall((:Py_IsInitialized, PythonCall.C.libpython), Cint, ()) != 0
            py_alive && shutdown_cleanly!()
        catch
            # Swallow silently — logging exception payloads at exit causes GC
            # walks across Python objects → segfault. Process is exiting anyway.
        end
    end

    println("⚡ SPARKBYTE LATTICE BOOTING...")

    # Boot A2A server alongside SparkByte
    engine_ref = Ref(engine)
    start_a2a_server(db; engine_ref=engine_ref)
    public_a2a_handler = req -> handle_public_a2a_request(req, db; engine_ref=engine_ref)

    # SparkByte's own autonomous heartbeat — default OFF, opt-in via
    # SPARKBYTE_AUTOPILOT_SECONDS.  Broadcasts autopilot_queued →
    # autopilot_thinking → autopilot_acted over the UI WebSocket so the queue
    # chip and thought bubble light up live.  Shares engine_ref with the A2A
    # server so she can reflect on her actual working state.
    _autopilot_start!(engine_ref, db, root)

    if launch_browser
        @async try
            sleep(2)
            BYTE.launch(port)
        catch e
            @warn "Browser launch failed" exception=(e, catch_backtrace())
        end
    end
    BYTE.serve(engine; host=host, port=port, extra_http_handler=public_a2a_handler)
    return
end

function julia_main()::Cint
    try
        app_main()
        return 0
    catch err
        Base.display_error(stderr, err, catch_backtrace())
        return 1
    end
end
