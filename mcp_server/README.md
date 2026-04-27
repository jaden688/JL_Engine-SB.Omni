# SparkByte MCP Server

Exposes the JL-Engine / SparkByte runtime to any [Model Context Protocol](https://modelcontextprotocol.io) client (Claude Desktop, Claude Code, Cursor, Zed, ChatGPT custom MCP, VS Code Copilot).

Server name: **`sparkbyte`** (also registered as `JL-SB-Omni` in some configs).

---

## What it gives you

Two integration paths into the engine:

1. **Read-only DB tools** — direct queries against `sparkbyte_memory.db` and the embedded Julian quarry (`quarry.db`). Fast, no engine required.
2. **Live engine tools** — round-trip to the running SparkByte WebSocket (`ws://127.0.0.1:8081`) for real agent replies and forged-tool execution.

### Tool catalog

| Tool | Path | Description |
|---|---|---|
| `get_engine_state` | DB | Latest `turn_snapshots` row |
| `get_recent_telemetry(limit=20)` | DB | Recent telemetry events |
| `query_memory(tag="", key="", limit=20)` | DB | Filter memory rows by tag/key |
| `write_memory(tag, key, content)` | DB | Insert a new memory row |
| `list_agents` | DB | Registered agents (name, tone, active) |
| `list_forged_tools` | DB | Forged tools recorded in `tools` table |
| `list_forged_tools_registry` | FS | Dump `dynamic_tools_registry.json` (Julia runtime tools) |
| `search_julian_quarry(query, limit=10)` | DB | Full-text-ish scan of the code quarry |
| `ask_sparkbyte(prompt)` | WS | Direct chat with SparkByte |
| `ask_agent_<persona>(prompt)` | WS | Auto-generated per agent in DB (slappy, supervisor, the_gremlin, …) |
| `call_forged_tool(name, args?)` | WS | Invoke a Julia-runtime forged tool by name |

> Agent passthrough tools are registered dynamically at server start from the `agents` table — adding an agent to the DB and restarting the server exposes a new `ask_agent_*` tool automatically.

---

## Install / run

### Requirements
- Python 3.10+
- Install pinned deps: `pip install -r mcp_server/requirements.txt`
  (`mcp`, `websockets`, plus `uvicorn` for HTTP-mode auth)
- `sparkbyte_memory.db` at repo root (read-only access is fine)
- (Optional, for live tools) SparkByte WS server running on `127.0.0.1:8081`

### Run modes

```bash
# stdio (default — what Claude Desktop / Claude Code use)
python mcp_server/server.py

# SSE / HTTP (for ChatGPT custom MCP, browser clients)
python mcp_server/server.py --http
# → http://127.0.0.1:8083/sse

# Streamable-HTTP (FastMCP default, port 8000)
python mcp_server/http_server.py
```

### Environment overrides

| Var | Default | Purpose |
|---|---|---|
| `MCP_TRANSPORT` | `stdio` | Set to `sse` or `http` to switch transport |
| `MCP_PORT` | `8083` | Port for SSE mode |
| `MCP_BIND` | `127.0.0.1` | Bind address. Non-loopback requires the ack + auth (see Security) |
| `MCP_BIND_ACK` | _(unset)_ | Set to `I_understand_no_builtin_auth` to allow non-loopback bind |
| `MCP_AUTH_TOKEN` | _(unset)_ | Bearer token required for non-loopback HTTP/SSE (≥16 chars) |
| `MCP_WS_CONCURRENCY` | `4` | Max in-flight WS round-trips |
| `MCP_ALLOW_EXTERNAL_PATHS` | `0` | `1` skips path-sandbox check on JULIAN_DB / JULIAN_SKILL |
| `MCP_ALLOW_REMOTE_WS` | `0` | `1` allows non-loopback `SPARKBYTE_WS` |
| `MCP_LOG_LEVEL` | `INFO` | stderr log level (DEBUG/INFO/WARNING/ERROR) |
| `SPARKBYTE_WS` | `ws://127.0.0.1:8081` | Where the live engine is listening |
| `SPARKBYTE_WS_TIMEOUT` | `60` | Seconds to wait for a `spark` reply |
| `MCP_MAX_RESPONSE_BYTES` | `60000` | Cap for `query_memory` / `list_forged_tools_registry` output |
| `JULIAN_DB` | `JulianMetaMorph/JulianMetaMorph/data/quarry.db` | Path to quarry |
| `JULIAN_SKILL` | `~/.claude/skills/julian/SKILL.md` | Julian skill markdown |

---

## Client setup

### Claude Desktop (`%APPDATA%\Claude\claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "sparkbyte": {
      "command": "python",
      "args": [
        "C:\\Users\\J_lin\\Desktop\\jl-engine-reboot-reboot\\JL_Engine-SB.Omni\\mcp_server\\server.py"
      ]
    }
  }
}
```

Restart Claude Desktop to pick up changes.

### Claude Code

Either reuse the Claude Desktop entry above, or add a project-scoped `.mcp.json` at the repo root:

```json
{
  "mcpServers": {
    "sparkbyte": {
      "command": "python",
      "args": ["mcp_server/server.py"]
    }
  }
}
```

### Cursor / Zed / VS Code Copilot

Same shape — point at `python mcp_server/server.py` (stdio).

### ChatGPT custom MCP

Run in SSE mode and give ChatGPT the URL:

```
python mcp_server/server.py --http
# → http://127.0.0.1:8083/sse
```

---

## How forged tools work

SparkByte's runtime forge writes tool **metadata** to `dynamic_tools_registry.json` and the **implementation** to `dynamic_tools.jl` (Julia). These are loaded into the live engine, *not* into the SQLite `tools` table — so `list_forged_tools` (DB) and `list_forged_tools_registry` (filesystem) can show different things.

To invoke one from an MCP client:

```python
call_forged_tool("coin_flip")
call_forged_tool("word_count", {"text": "the quick brown fox"})
```

Internally this round-trips through `ask_sparkbyte` over WS, so the engine must be running.

---

## Architecture

```
┌──────────────────┐    stdio / sse        ┌────────────────────────┐
│  MCP client      │◄────────────────────►│  mcp_server/server.py  │
│  (Claude/Cursor) │                       │  (FastMCP, this file)  │
└──────────────────┘                       └──────┬─────────┬───────┘
                                                  │         │
                                       sqlite ro  │         │ ws://…:8081
                                                  ▼         ▼
                                  sparkbyte_memory.db   SparkByte engine
                                  quarry.db              (Julia + Python)
```

- DB tools are synchronous, return JSON strings.
- WS tools are `async`, await `_ws_ask` which filters the SparkByte WS protocol for `spark` (reply) and `error` messages, ignoring noise (`generation_started`, `ui_update`, `tool`, `engine_state`, `telemetry_update`).
- Agent passthrough tools are generated at import time from the `agents` table — silent failure if the DB is missing.

---

## Security

Default posture is **localhost-only, no auth**. To expose this server beyond your machine:

1. Set `MCP_BIND=0.0.0.0` (or a specific NIC IP).
2. Set `MCP_BIND_ACK=I_understand_no_builtin_auth` — the server refuses to start otherwise.
3. Set `MCP_AUTH_TOKEN` to a random ≥16-char string. Clients must send `Authorization: Bearer <token>`.
4. Install `uvicorn` (already in `requirements.txt`) — needed when auth is on.
5. **Front it with TLS** (Caddy, nginx, Cloudflare). The bundled auth is a Bearer check, not transport security.

Other guardrails enforced by default:

- `JULIAN_DB` and `JULIAN_SKILL` paths must resolve under the repo root or `$HOME`. Override with `MCP_ALLOW_EXTERNAL_PATHS=1`.
- `SPARKBYTE_WS` must be loopback. Override with `MCP_ALLOW_REMOTE_WS=1`.
- WS round-trips are bounded by `MCP_WS_CONCURRENCY` (default 4) — prevents fan-out DoS.
- Caller input to `ask_sparkbyte` / `ask_agent_*` is sanitized (control chars + `[SYSTEM ...]` markers stripped, 4kB cap).
- `call_forged_tool` strips non-alphanumeric chars from the tool `name` and JSON-validates `args` before dispatch.
- All read-only DB tools open with `mode=ro`. Only `write_memory` opens RW.

## Known limitations

- `query_memory` and `list_forged_tools_registry` cap output at `MCP_MAX_RESPONSE_BYTES` (default 60kB). Capped responses come back as `{truncated: true, preview, hint}` — narrow the query or raise the cap.
- WS reply timeout is `SPARKBYTE_WS_TIMEOUT` (default 60s); raise it for long agent thinks.
- If `ask_agent_*` tools are missing, check stderr — `_register_agent_tools` logs the exception (usually a missing DB or schema drift in the `agents` table).
- DB writes (`write_memory`) are read-write; the rest of the DB tools open the file with `mode=ro`.
- No auth on SSE/HTTP transports — bind to localhost only or front with a reverse proxy if exposing.

---

## Smoke test

```bash
python mcp_server/smoke_test.py            # DB tools only
RUN_WS=1 python mcp_server/smoke_test.py   # also hit live engine
```

Expects 7/7 (DB) or 9/9 (with WS).

---

## Verifying after a config change

After editing `server.py`, restart the MCP client and:

```
list_forged_tools_registry()       # should dump dynamic_tools_registry.json
ask_sparkbyte("ping")              # should return a sparkbyte reply
call_forged_tool("coin_flip")      # should return "heads" or "tails"
```

If `ask_sparkbyte` returns `[SparkByte unreachable: ...]`, the engine WS isn't running on `SPARKBYTE_WS`.
