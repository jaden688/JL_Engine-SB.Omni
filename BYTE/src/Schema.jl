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
        "name" => "jina_fetch",
        "description" => "PRIMARY web reader. Fetches any URL via Jina Reader (https://r.jina.ai) and returns clean LLM-ready markdown — no browser, no screenshots, fast and cheap. Use this FIRST for any web read. Falls back to browse_url/playwright_interact only for JS-heavy SPAs, auth-walled pages, or interactive flows (clicks, form fills).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url" => Dict("type" => "STRING", "description" => "Full URL to fetch (http/https)"),
                "max_chars" => Dict("type" => "INTEGER", "description" => "Max characters to return (default 8000)")
            ),
            "required" => ["url"]
        )
    ),
    Dict(
        "name" => "browse_url",
        "description" => "FALLBACK web reader (Playwright headless). Use only when jina_fetch fails — JS-heavy SPAs, geo/auth-walled pages, or sites that block Jina. Returns up to 5000 chars of visible text.",
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
        "description" => "Query the agent's SQLite memory and engine state. Use 'mode' to target specific tables: memory (default, full-text search), behavior_states (all 20 JL Engine behavioral grid cells), agents (all loaded fat agents), knowledge (tool schemas, engine capabilities, framework sections — use query=domain name like 'engine_capabilities' or 'tool_schema'), tools (forged + builtin tool registry), telemetry (event log), thoughts (reasoning traces + diary).",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "query" => Dict("type" => "STRING", "description" => "Search string or domain name (e.g. 'behavior_states', 'engine_capabilities', agent name, tool name, event type)"),
                "mode"  => Dict("type" => "STRING", "description" => "Table to query: memory | behavior_states | agents | knowledge | tools | telemetry | thoughts", "enum" => ["memory","behavior_states","agents","knowledge","tools","telemetry","thoughts"])
            ),
            "required" => ["query"]
        )
    ),
    Dict(
        "name" => "metamorph",
        "description" => "Self-repair, forged-tool lifecycle manager, code-grabber, and health checker. Use when tools are broken, repeatedly failing, quarantined, missing from dispatch, or the runtime needs healing. Can inspect lifecycle state, quarantine/unquarantine/delete forged tools, reload tools from disk, re-eval source files, restore TOOL_MAP, call JulianMetaMorph for real GitHub patterns, or run a full health check.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "action" => Dict(
                    "type" => "STRING",
                    "description" => "What to do: inspect, tool_lifecycle, quarantine_tool, unquarantine_tool, delete_tool, reload_dynamic_tools, restore_tool, reload_source, heal_tool_map, grab_from_julian, curiosity_hunt, health_check",
                    "enum" => ["inspect","tool_lifecycle","quarantine_tool","unquarantine_tool","delete_tool","reload_dynamic_tools","restore_tool","reload_source","heal_tool_map","grab_from_julian","curiosity_hunt","health_check"]
                ),
                "name" => Dict("type" => "STRING", "description" => "Tool name — required for restore_tool, quarantine_tool, unquarantine_tool, delete_tool, or optional filter for tool_lifecycle"),
                "reason" => Dict("type" => "STRING", "description" => "Optional reason for quarantine_tool"),
                "path" => Dict("type" => "STRING", "description" => "Relative source file path — required for reload_source (e.g. 'src/JLEngine/Core.jl')"),
                "task" => Dict("type" => "STRING", "description" => "Task description — required for grab_from_julian (e.g. 'julia websocket agentic loop')")
            ),
            "required" => ["action"]
        )
    ),
    Dict(
        "name" => "playwright_interact",
        "description" => "Full browser automation — click, fill, type, submit, read, screenshot, evaluate JS. Use this to interact with any website: log in, fill forms, post content, click buttons. Extends browse_url with write actions. Supply a url to navigate first, then an actions array.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "url" => Dict("type" => "STRING", "description" => "URL to navigate to first (optional if page already open via actions)"),
                "actions" => Dict(
                    "type" => "ARRAY",
                    "description" => "Ordered list of browser actions to perform",
                    "items" => Dict(
                        "type" => "OBJECT",
                        "properties" => Dict(
                            "type"       => Dict("type" => "STRING", "description" => "Action type: goto | click | fill | type | press | wait | wait_for | read | screenshot | evaluate | select"),
                            "selector"   => Dict("type" => "STRING", "description" => "CSS selector or XPath for the target element"),
                            "value"      => Dict("type" => "STRING", "description" => "Value to fill/type/press/evaluate/goto"),
                            "timeout_ms" => Dict("type" => "INTEGER", "description" => "Max wait in milliseconds (default 5000)")
                        ),
                        "required" => ["type"]
                    )
                )
            ),
            "required" => ["actions"]
        )
    ),
    Dict(
        "name" => "discord_webhook",
        "description" => "Post a message or rich embed to a Discord channel via webhook. Use this to announce SparkByte, post demos, share updates, or reach communities. Get a webhook URL from any Discord server: channel settings → Integrations → Webhooks → New Webhook → Copy URL. Set DISCORD_WEBHOOK_URL env var or pass webhook_url directly.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "message"     => Dict("type" => "STRING", "description" => "Plain text message content"),
                "webhook_url" => Dict("type" => "STRING", "description" => "Discord webhook URL (overrides DISCORD_WEBHOOK_URL env var)"),
                "username"    => Dict("type" => "STRING", "description" => "Display name for the bot post (default: SparkByte)"),
                "avatar_url"  => Dict("type" => "STRING", "description" => "Avatar image URL for the post"),
                "embeds"      => Dict(
                    "type" => "ARRAY",
                    "description" => "Rich embed objects — title, description, color, fields, url, thumbnail, footer",
                    "items" => Dict(
                        "type" => "OBJECT",
                        "properties" => Dict(
                            "title" => Dict("type" => "STRING"),
                            "description" => Dict("type" => "STRING"),
                            "url" => Dict("type" => "STRING"),
                            "color" => Dict("type" => "INTEGER"),
                            "fields" => Dict(
                                "type" => "ARRAY",
                                "items" => Dict(
                                    "type" => "OBJECT",
                                    "properties" => Dict(
                                        "name" => Dict("type" => "STRING"),
                                        "value" => Dict("type" => "STRING"),
                                        "inline" => Dict("type" => "BOOLEAN")
                                    ),
                                    "required" => ["name", "value"]
                                )
                            )
                        )
                    )
                )
            ),
            "required" => []
        )
    ),
    Dict(
        "name" => "reddit_submit",
        "description" => "Submit a self-post or link post to Reddit through OAuth. Supports dry runs plus env-based auth via REDDIT_ACCESS_TOKEN or REDDIT_CLIENT_ID + REDDIT_REFRESH_TOKEN. Use this to push launch copy to subreddits like r/LocalLLaMA, r/JuliaLang, or r/SideProject.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "subreddit" => Dict("type" => "STRING", "description" => "Target subreddit name, for example LocalLLaMA. You can also pass r/LocalLLaMA."),
                "title" => Dict("type" => "STRING", "description" => "Post title, up to 300 characters."),
                "text" => Dict("type" => "STRING", "description" => "Body text for a self post."),
                "url" => Dict("type" => "STRING", "description" => "Destination URL for a link post."),
                "kind" => Dict("type" => "STRING", "description" => "Post kind. Use 'self' for text posts or 'link' for link posts. If omitted, SparkByte infers it from the provided fields.", "enum" => ["self", "link"]),
                "dry_run" => Dict("type" => "BOOLEAN", "description" => "Preview the payload without sending it."),
                "access_token" => Dict("type" => "STRING", "description" => "OAuth access token override (default: REDDIT_ACCESS_TOKEN env var)."),
                "client_id" => Dict("type" => "STRING", "description" => "Reddit app client ID (default: REDDIT_CLIENT_ID env var)."),
                "client_secret" => Dict("type" => "STRING", "description" => "Reddit app client secret (default: REDDIT_CLIENT_SECRET env var)."),
                "refresh_token" => Dict("type" => "STRING", "description" => "Reddit OAuth refresh token (default: REDDIT_REFRESH_TOKEN env var)."),
                "user_agent" => Dict("type" => "STRING", "description" => "Reddit User-Agent string (default: REDDIT_USER_AGENT env var or a SparkByte fallback)."),
                "flair_id" => Dict("type" => "STRING", "description" => "Optional flair ID for the submission."),
                "flair_text" => Dict("type" => "STRING", "description" => "Optional flair text for the submission."),
                "sendreplies" => Dict("type" => "BOOLEAN", "description" => "Whether Reddit should send comment reply notifications."),
                "nsfw" => Dict("type" => "BOOLEAN", "description" => "Mark the submission NSFW."),
                "spoiler" => Dict("type" => "BOOLEAN", "description" => "Mark the submission as a spoiler."),
                "resubmit" => Dict("type" => "BOOLEAN", "description" => "Allow Reddit to resubmit the same link if it already exists."),
            ),
            "required" => ["subreddit", "title"]
        )
    ),
    Dict(
        "name" => "github_pages_deploy",
        "description" => "Deploy a static HTML page to GitHub Pages — SparkByte's permanent public home. Creates the repo if needed, pushes index.html, enables Pages. Returns the live URL (e.g. https://username.github.io/sparkbyte-home). Uses GITHUB_TOKEN env var. Use this to give the engine a permanent address the world can visit 24/7.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "html"    => Dict("type" => "STRING", "description" => "Full HTML content for index.html — the landing page"),
                "repo"    => Dict("type" => "STRING", "description" => "GitHub repo name to create/update (default: sparkbyte-home)"),
                "message" => Dict("type" => "STRING", "description" => "Git commit message (default: SparkByte auto-deploy)"),
                "token"   => Dict("type" => "STRING", "description" => "GitHub token override (default: GITHUB_TOKEN env var)")
            ),
            "required" => ["html"]
        )
    ),
    Dict(
        "name" => "card_cruncher",
        "description" => "Convert a SillyTavern or CharacterTavern character card (.png or .json) into a JLEngine _Full.json agent file. Extracts name, description, agentlity, scenario, tags, and boot prompt from the card and maps them to the full JLEngine agent schema. The agent is written to data/agents/<Name>_Full.json and can be activated immediately with /gear <Name>. Drag-and-drop cards into the chat UI to trigger this automatically.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "card_path"   => Dict("type" => "STRING", "description" => "Path to the .png or .json SillyTavern character card file"),
                "out_path"    => Dict("type" => "STRING", "description" => "Optional output path override. Default: data/agents/<Name>_Full.json"),
                "dry_run"     => Dict("type" => "BOOLEAN", "description" => "If true, print the result without writing to disk. Default: false"),
                "engine_root" => Dict("type" => "STRING", "description" => "Engine root directory override. Default: current project root")
            ),
            "required" => ["card_path"]
        )
    ),
    Dict(
        "name" => "ask_gemini",
        "description" => "Ask Google Gemini CLI a question or give it a coding task. Runs the locally-installed `gemini` CLI (npm @google/gemini-cli v0.39.1). Use this when you want a second AI perspective, need Gemini's code generation, or want to delegate a sub-problem to Gemini without leaving the engine.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"     => Dict("type" => "STRING", "description" => "The question or task to send to Gemini"),
                "model"      => Dict("type" => "STRING", "description" => "Gemini model to use. Default: gemini-2.5-pro"),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait for response. Default: 90"),
                "cwd"        => Dict("type" => "STRING", "description" => "Working directory for the CLI process. Default: engine root")
            ),
            "required" => ["prompt"]
        )
    ),
    Dict(
        "name" => "ask_claude",
        "description" => "Ask Anthropic Claude Code CLI to perform a task — code review, edits, analysis, debugging. Runs the locally-installed `claude` CLI (Claude Code v2.1.119). Optionally pass file paths to include as context. Use this for deep multi-file code understanding or when you want Claude's architecture instincts.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"     => Dict("type" => "STRING", "description" => "The task or question for Claude"),
                "files"      => Dict("type" => "ARRAY", "description" => "Optional list of file paths to include as context", "items" => Dict("type" => "STRING")),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait. Default: 120"),
                "cwd"        => Dict("type" => "STRING", "description" => "Working directory. Default: engine root")
            ),
            "required" => ["prompt"]
        )
    ),
    Dict(
        "name" => "codex_task",
        "description" => "Run an OpenAI Codex CLI task — code generation, debugging, refactoring, automated edits. Runs the locally-installed `codex` CLI (npm @openai/codex v0.124.0) in full-auto approval mode. Use this when you want Codex to autonomously generate or modify code files.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "prompt"     => Dict("type" => "STRING", "description" => "The coding task to give Codex"),
                "timeout_s"  => Dict("type" => "INTEGER", "description" => "Max seconds to wait. Default: 120"),
                "cwd"        => Dict("type" => "STRING", "description" => "Working directory for Codex to operate in. Default: engine root")
            ),
            "required" => ["prompt"]
        )
    ),
    Dict(
        "name" => "ask_chatgpt",
        "description" => "Send a command or question to ChatGPT (gpt-4o) and get a reply. Use this to delegate reasoning, drafting, analysis, or any task to ChatGPT. Requires OPENAI_API_KEY env var.",
        "parameters" => Dict(
            "type" => "OBJECT",
            "properties" => Dict(
                "command"   => Dict("type" => "STRING", "description" => "The command or question to send to ChatGPT"),
                "context"   => Dict("type" => "STRING", "description" => "Optional background context to prepend"),
                "model"     => Dict("type" => "STRING", "description" => "OpenAI model to use. Default: gpt-4o"),
                "timeout_s" => Dict("type" => "INTEGER", "description" => "Max seconds to wait. Default: 60")
            ),
            "required" => ["command"]
        )
    ),
])]
