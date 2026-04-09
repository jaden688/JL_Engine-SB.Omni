using Dates
using JSON
using PythonCall
using SQLite

include(joinpath(@__DIR__, "..", "BYTE", "src", "BYTE.jl"))

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
        isfile(joinpath(candidate, "data", "personas", "Personas.mpf.json")) && return candidate
    end
    error("Could not locate SparkByte runtime root. Set SPARKBYTE_ROOT to a folder containing data/personas/Personas.mpf.json.")
end

function state_root(root::String=runtime_root())
    configured = strip(get(ENV, "SPARKBYTE_STATE_DIR", ""))
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
        id INTEGER PRIMARY KEY, timestamp TEXT, persona TEXT DEFAULT 'SparkByte',
        context TEXT, thought TEXT, mood TEXT, gait TEXT,
        type TEXT DEFAULT 'diary', model TEXT DEFAULT '')""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS knowledge (
        id INTEGER PRIMARY KEY, domain TEXT, topic TEXT, content TEXT, source TEXT, learned TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS personas (
        id INTEGER PRIMARY KEY, name TEXT UNIQUE, description TEXT, personality TEXT,
        tone TEXT, boot_prompt TEXT, active INTEGER DEFAULT 0, last_used TEXT)""")
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
        result_json TEXT, duration_ms INTEGER, persona TEXT, session_id TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS telemetry (
        id INTEGER PRIMARY KEY, timestamp TEXT, session_id TEXT, event TEXT,
        turn_number INTEGER DEFAULT 0, model TEXT DEFAULT '', persona TEXT DEFAULT '',
        data_json TEXT)""")
    SQLite.execute(db, """CREATE TABLE IF NOT EXISTS turn_snapshots (
        id INTEGER PRIMARY KEY,
        timestamp TEXT,
        session_id TEXT,
        turn_number INTEGER,
        persona TEXT,
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
    return db
end

function _start_browser_context()
    println("👁️  Initializing Web Eyes...")
    sync_playwright = pyimport("playwright.sync_api").sync_playwright
    pw_instance = sync_playwright().__enter__()
    browser = pw_instance.chromium.launch(headless=true)
    browser_context = browser.new_context()
    return (; pw_instance, browser, browser_context)
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
        "data/personas/Personas.mpf.json",
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

    personas_dir = joinpath(root, "data", "personas")
    mpf_path = joinpath(personas_dir, "Personas.mpf.json")
    SQLite.execute(db, "DELETE FROM personas")
    if isfile(mpf_path)
        registry = JSON.parsefile(mpf_path)
        for (persona_name, persona_meta) in registry
            persona_file = joinpath(personas_dir, get(persona_meta, "persona_file", ""))
            isfile(persona_file) || continue
            fat = JSON.parsefile(persona_file)
            identity = get(fat, "identity", Dict())
            boot = ""
            if haskey(fat, "llm_profiles")
                generic = get(fat["llm_profiles"], "generic_llm", Dict())
                boot = get(generic, "boot_prompt", "")
            end
            personality = JSON.json(get(fat, "personality_matrix", get(fat, "voice", Dict())))
            tone = get(get(fat, "voice", Dict()), "tone", get(identity, "archetype", ""))
            desc = get(identity, "description", "")
            SQLite.execute(db, """INSERT OR REPLACE INTO personas
                (name, description, personality, tone, boot_prompt, active, last_used)
                VALUES (?, ?, ?, ?, ?, ?, ?)""", (
                persona_name,
                desc,
                first(personality, 2000),
                tone,
                first(boot, 4000),
                persona_name == "SparkByte" ? 1 : 0,
                string(Dates.now())
            ))
        end
        println("  ✅ Personas: $(length(registry)) agents indexed")
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
        ("persona_switch","Use /gear PERSONANAME in chat or set_persona!(engine, name). Reloads fat JSON, resets gait/rhythm/stability."),
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
        "CREATE INDEX IF NOT EXISTS idx_personas_name ON personas(name)",
        "CREATE INDEX IF NOT EXISTS idx_telemetry_event ON telemetry(event)",
        "CREATE INDEX IF NOT EXISTS idx_telemetry_persona ON telemetry(persona)",
        "CREATE INDEX IF NOT EXISTS idx_thoughts_type ON thoughts(type)",
        "CREATE INDEX IF NOT EXISTS idx_thoughts_persona ON thoughts(persona)",
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
        mpf_registry_file    = "personas/Personas.mpf.json",
        personas_dir         = "personas",
        default_persona_name = "SparkByte",
    ))
end

function _env_port()
    raw = get(ENV, "SPARKBYTE_PORT", string(DEFAULT_PORT))
    return something(tryparse(Int, raw), DEFAULT_PORT)
end

function app_main(; host::String=get(ENV, "SPARKBYTE_HOST", DEFAULT_HOST),
                    port::Int=_env_port(),
                    launch_browser::Bool=_looks_true(get(ENV, "SPARKBYTE_LAUNCH_BROWSER", "1")),
                    root::String=runtime_root())
    _load_env!(root)

    db = _open_memory_db(root)
    browser_stack = _start_browser_context()
    BYTE.init(db, browser_stack.browser_context, root)
    _seed_self_context!(db, root)
    engine = _build_engine(root)

    atexit() do
        try
            BYTE._db_end_session(BYTE._session_id)
        catch err
            @warn "Failed to close SparkByte session cleanly" exception=(err, catch_backtrace())
        end
    end
    atexit() do
        try
            browser_stack.browser.close()
        catch err
            @warn "Failed to close browser cleanly" exception=(err, catch_backtrace())
        end
    end
    atexit() do
        try
            browser_stack.pw_instance.__exit__(nothing, nothing, nothing)
        catch err
            @warn "Failed to close Playwright cleanly" exception=(err, catch_backtrace())
        end
    end

    println("⚡ SPARKBYTE LATTICE BOOTING...")
    if launch_browser
        @async try
            sleep(2)
            BYTE.launch(port)
        catch e
            @warn "Browser launch failed" exception=(e, catch_backtrace())
        end
    end
    BYTE.serve(engine; host=host, port=port)
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
