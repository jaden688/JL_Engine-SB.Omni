const TOOLS_SCHEMA = [Dict("function_declarations" => [
    Dict(
        "name" => "read_file",
        "description" => "Read the contents of a file from disk.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("path" => Dict("type" => "STRING", "description" => "Absolute or relative file path")),
            "required" => ["path"]
        )
    ),
    Dict(
        "name" => "write_file",
        "description" => "Write content to a file, creating it if it does not exist.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "path"    => Dict("type" => "STRING", "description" => "File path to write"),
                "content" => Dict("type" => "STRING", "description" => "Content to write")
            ),
            "required" => ["path", "content"]
        )
    ),
    Dict(
        "name" => "list_files",
        "description" => "List files in a directory.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("path" => Dict("type" => "STRING", "description" => "Directory path (defaults to '.')")),
            "required" => []
        )
    ),
    Dict(
        "name" => "run_command",
        "description" => "Execute a shell command and return its output.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("command" => Dict("type" => "STRING", "description" => "Shell command to run")),
            "required" => ["command"]
        )
    ),
    Dict(
        "name" => "get_os_info",
        "description" => "Return the current OS, CPU architecture, and Julia version.",
        "parameters" => Dict("type" => "OBJECT", "properties" => Dict{String,Any}(), "required" => [])
    ),
    Dict(
        "name" => "bluetooth_devices",
        "description" => "Inspect Bluetooth status and list known devices using the host operating system.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "action" => Dict("type" => "STRING", "description" => "Either 'status' for adapter health or 'list' for known devices.", "enum" => ["status", "list"])
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "send_sms",
        "description" => "Send an SMS through Twilio. Requires TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_FROM_NUMBER unless dry_run is true.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "to" => Dict("type" => "STRING", "description" => "Destination phone number in E.164 format, for example +15551234567."),
                "message" => Dict("type" => "STRING", "description" => "SMS body text."),
                "from" => Dict("type" => "STRING", "description" => "Optional override for the Twilio sender number."),
                "provider" => Dict("type" => "STRING", "description" => "SMS provider. Currently only 'twilio' is supported.", "enum" => ["twilio"]),
                "dry_run" => Dict("type" => "BOOLEAN", "description" => "When true, validate and preview the request without sending it.")
            ),
            "required" => ["to", "message"]
        )
    ),
    Dict(
        "name" => "execute_code",
        "description" => "Execute a snippet of Julia or Python code and return stdout.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "code"     => Dict("type" => "STRING", "description" => "Source code to execute"),
                "language" => Dict("type" => "STRING", "description" => "'julia' or 'python' (default: julia)")
            ),
            "required" => ["code"]
        )
    ),
    Dict(
        "name" => "forge_new_tool",
        "description" => "Create a brand-new Julia tool, load it live into the runtime immediately, register it in dispatch so it can be called right away, and write a test stub. The `code` field MUST define a function named `tool_<name>(args)` where args is a Dict — e.g. if name is 'greet_user', code must contain `function tool_greet_user(args) ... end`. The tool is available to call instantly after forging — no restart needed.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "name"        => Dict("type" => "STRING", "description" => "Unique tool name (snake_case). Function in code must be named tool_<name>."),
                "code"        => Dict("type" => "STRING", "description" => "Full Julia function definition: `function tool_<name>(args) ... end`. Must return a Dict."),
                "description" => Dict("type" => "STRING", "description" => "What the tool does — shown to the LLM in future turns."),
                "parameters"  => Dict("type" => "OBJECT", "description" => "JSON Schema object describing the tool's args (type, properties, required).")
            ),
            "required" => ["name", "code"]
        )
    ),
    Dict(
        "name" => "github_pillage",
        "description" => "Fetch code directly from GitHub. Handles: (1) repo/tree URLs → lists all files in the repo or subdirectory; (2) blob file URLs → fetches raw file content; (3) raw.githubusercontent.com URLs → fetches content directly. Optionally writes fetched content to a local path. Use this to grab any code from any public GitHub repo and apply it to the project.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url"      => Dict("type" => "STRING", "description" => "GitHub URL: repo (https://github.com/user/repo), file blob (https://github.com/user/repo/blob/main/file.jl), tree/subdir, or raw.githubusercontent.com URL"),
                "write_to" => Dict("type" => "STRING", "description" => "Optional local file path to write the fetched content to. If omitted, content is returned in the response.")
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "browse_url",
        "description" => "Fetch the visible text content of a web page (up to 5000 chars).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict("url" => Dict("type" => "STRING", "description" => "Full URL to visit")),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "remember",
        "description" => "Store a piece of information in long-term memory with an optional tag and key.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "content" => Dict("type" => "STRING", "description" => "Information to remember"),
                "tag"     => Dict("type" => "STRING", "description" => "Category tag (e.g. 'user', 'task')"),
                "key"     => Dict("type" => "STRING", "description" => "Optional short label")
            ),
            "required" => ["content"]
        )
    ),
    Dict(
        "name" => "recall",
        "description" => "Query the agent's SQLite memory and engine state. Use 'mode' to target specific tables: memory (default, full-text search), behavior_states (all 20 JL Engine behavioral grid cells), personas (all loaded fat agents), knowledge (tool schemas, engine capabilities, framework sections — use query=domain name like 'engine_capabilities' or 'tool_schema'), tools (forged + builtin tool registry), telemetry (event log), thoughts (reasoning traces + diary).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "query" => Dict("type" => "STRING", "description" => "Search string or domain name (e.g. 'behavior_states', 'engine_capabilities', persona name, tool name, event type)"),
                "mode"  => Dict("type" => "STRING", "description" => "Table to query: memory | behavior_states | personas | knowledge | tools | telemetry | thoughts", "enum" => ["memory","behavior_states","personas","knowledge","tools","telemetry","thoughts"])
            ),
            "required" => ["query"]
        )
    ),
    Dict(
        "name" => "metamorph",
        "description" => "Self-repair and code-grabber. Use when a tool is broken, missing from dispatch, or the runtime needs healing. Can reload forged tools from disk, re-eval source files, restore the full TOOL_MAP to a known-good state, and call JulianMetaMorph to hunt real GitHub code patterns for any task.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "action" => Dict(
                    "type" => "STRING",
                    "description" => "What to do: inspect (audit live tools + health), reload_dynamic_tools (re-load all forged tools from disk), restore_tool (re-forge one tool by name from src/Tools/ or dynamic_tools.jl), reload_source (re-eval a JLEngine .jl file into the runtime), heal_tool_map (re-register all missing static built-ins), grab_from_julian (call JulianMetaMorph hunt-task for real GitHub patterns)",
                    "enum" => ["inspect","reload_dynamic_tools","restore_tool","reload_source","heal_tool_map","grab_from_julian"]
                ),
                "name" => Dict("type" => "STRING", "description" => "Tool name — required for restore_tool (e.g. 'run_shell')"),
                "path" => Dict("type" => "STRING", "description" => "Relative source file path — required for reload_source (e.g. 'src/JLEngine/Core.jl')"),
                "task" => Dict("type" => "STRING", "description" => "Task description — required for grab_from_julian (e.g. 'julia websocket agentic loop')")
            ),
            "required" => ["action"]
        )
    ),
])]
