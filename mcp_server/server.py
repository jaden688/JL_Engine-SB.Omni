"""
SparkByte MCP Server — dual transport.
- stdio mode  (default): for VS Code Copilot and Claude Desktop
- sse mode:              for ChatGPT "New App" MCP URL  (http://127.0.0.1:8083/sse)

Usage:
  stdio:  python server.py
  sse:    python server.py --http
  or set: MCP_TRANSPORT=sse
"""

import sqlite3
import json
import os
import sys
import asyncio
import websockets
import uuid
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).parent.parent
SB_DB = ROOT / "sparkbyte_memory.db"
_EMBEDDED_QUARRY = ROOT / "JulianMetaMorph" / "JulianMetaMorph" / "data" / "quarry.db"
JUL_DB = Path(os.environ.get("JULIAN_DB", str(_EMBEDDED_QUARRY)))
SKILL_MD = Path(os.environ.get("JULIAN_SKILL", str(Path.home() / ".claude" / "skills" / "julian" / "SKILL.md")))

_MCP_PORT = int(os.environ.get("MCP_PORT", "8083"))
_USE_HTTP  = "--http" in sys.argv or os.environ.get("MCP_TRANSPORT", "").lower() in ("sse", "http")
_MCP_HOST  = "0.0.0.0" if _USE_HTTP else "127.0.0.1"
_MAX_BYTES = int(os.environ.get("MCP_MAX_RESPONSE_BYTES", "60000"))
_WS_TIMEOUT = float(os.environ.get("SPARKBYTE_WS_TIMEOUT", "60"))

def _cap(payload: str, kind: str = "result") -> str:
    """Truncate large JSON payloads so MCP clients don't choke."""
    if len(payload) <= _MAX_BYTES:
        return payload
    return json.dumps({
        "truncated": True,
        "kind": kind,
        "original_bytes": len(payload),
        "max_bytes": _MAX_BYTES,
        "preview": payload[:_MAX_BYTES],
        "hint": "Narrow your query (use tag/key filters or smaller limit), or raise MCP_MAX_RESPONSE_BYTES.",
    }, indent=2)

mcp = FastMCP("sparkbyte", host=_MCP_HOST, port=_MCP_PORT)

# ── DB helpers (read-only) ─────────────────────────────────────────────────────
def _sb(query: str, params: tuple = ()) -> list[dict]:
    if not SB_DB.exists():
        return [{"error": "sparkbyte_memory.db not found"}]
    con = sqlite3.connect(f"file:{SB_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(query, params).fetchall()
        return [dict(r) for r in rows]
    finally:
        con.close()

def _jul(query: str, params: tuple = ()) -> list[dict]:
    if not JUL_DB.exists():
        return [{"error": "quarry.db not found"}]
    con = sqlite3.connect(f"file:{JUL_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(query, params).fetchall()
        return [dict(r) for r in rows]
    finally:
        con.close()

# ── Tools ──────────────────────────────────────────────────────────────────────
@mcp.tool()
def get_engine_state() -> str:
    """Latest SparkByte engine snapshot."""
    rows = _sb("SELECT * FROM turn_snapshots ORDER BY id DESC LIMIT 1")
    return json.dumps(rows[0] if rows else "No data", indent=2)

@mcp.tool()
def list_forged_tools() -> str:
    """List all runtime-forged tools."""
    rows = _sb("SELECT name, description, call_count FROM tools ORDER BY call_count DESC")
    return json.dumps(rows, indent=2)

@mcp.tool()
def query_memory(tag: str = "", key: str = "", limit: int = 20) -> str:
    """Query persistent memory. Output capped at MCP_MAX_RESPONSE_BYTES (default 60kB)."""
    limit = max(1, min(int(limit), 200))
    rows = _sb("SELECT tag, key, content FROM memory WHERE tag LIKE ? AND key LIKE ? LIMIT ?", (f"%{tag}%", f"%{key}%", limit))
    return _cap(json.dumps(rows, indent=2), kind="memory")

@mcp.tool()
def get_recent_telemetry(limit: int = 20) -> str:
    """Recent telemetry events."""
    rows = _sb("SELECT event, jl_agent, turn_number FROM telemetry ORDER BY id DESC LIMIT ?", (limit,))
    return json.dumps(rows, indent=2)

@mcp.tool()
def write_memory(tag: str, key: str, content: str) -> str:
    """Persist a memory entry (tag, key, content) to SparkByte's memory DB."""
    from datetime import datetime
    if not SB_DB.exists():
        return json.dumps({"error": "sparkbyte_memory.db not found"})
    con = sqlite3.connect(SB_DB)
    try:
        con.execute(
            "INSERT INTO memory (timestamp, tag, key, content) VALUES (?, ?, ?, ?)",
            (datetime.utcnow().isoformat(), tag, key, content),
        )
        con.commit()
        return json.dumps({"ok": True, "tag": tag, "key": key})
    finally:
        con.close()

@mcp.tool()
async def call_forged_tool(name: str, args: dict | None = None) -> str:
    """Invoke a runtime-forged tool (from dynamic_tools_registry.json) via SparkByte.

    Example: call_forged_tool("coin_flip") or call_forged_tool("word_count", {"text": "hi there"}).
    """
    args_json = json.dumps(args or {})
    prompt = (
        f"[SYSTEM TOOL CALL] Invoke forged tool `{name}` with args {args_json}. "
        f"Return ONLY the raw tool result, no commentary."
    )
    return await _ws_ask(prompt)

@mcp.tool()
def list_forged_tools_registry() -> str:
    """List forged tools from dynamic_tools_registry.json (Julia-runtime tools)."""
    reg = ROOT / "dynamic_tools_registry.json"
    if not reg.exists():
        return json.dumps({"error": "dynamic_tools_registry.json not found"})
    return _cap(reg.read_text(encoding="utf-8"), kind="forged_registry")

@mcp.tool()
def list_agents() -> str:
    """List all registered SparkByte agents with their tone and active flag."""
    rows = _sb("SELECT name, description, tone, active FROM agents ORDER BY name")
    return json.dumps(rows, indent=2)

@mcp.tool()
def search_julian_quarry(query: str, limit: int = 10) -> str:
    """Search Julian's code quarry."""
    rows = _jul("SELECT repo_full_name, file_path, language FROM files WHERE content LIKE ? LIMIT ?", (f"%{query}%", limit))
    return json.dumps(rows, indent=2)

# ── SparkByte WebSocket messenger ─────────────────────────────────────────────
_SB_WS = os.environ.get("SPARKBYTE_WS", "ws://127.0.0.1:8081")

async def _ws_ask(prompt: str, timeout: float | None = None) -> str:
    """Async WS call to SparkByte — must be awaited inside an async context."""
    # SparkByte WS protocol — message types observed:
    #   "generation_started" — engine starting, ignore
    #   "ui_update"          — gear/mode info, ignore
    #   "tool"               — tool call status, ignore
    #   "engine_state"       — perf snapshot, ignore
    #   "telemetry_update"   — metrics, ignore
    #   "spark"              — actual reply text (field: "text")  ← this is what we want
    #   "error"              — engine error (field: "text")
    REPLY_TYPES  = {"spark"}
    ERROR_TYPES  = {"error"}
    IGNORE_TYPES = {"generation_started", "ui_update", "tool", "engine_state", "telemetry_update"}
    if timeout is None:
        timeout = _WS_TIMEOUT
    try:
        async with websockets.connect(_SB_WS, open_timeout=5) as ws:
            payload = json.dumps({"type": "chat", "text": prompt, "id": str(uuid.uuid4())})
            await ws.send(payload)
            deadline = asyncio.get_event_loop().time() + timeout
            while asyncio.get_event_loop().time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
                    msg = json.loads(raw)
                    mtype = msg.get("type", "")
                    if mtype in REPLY_TYPES:
                        return msg.get("text") or msg.get("content") or msg.get("message") or str(msg)
                    if mtype in ERROR_TYPES:
                        return f"[SparkByte error: {msg.get('text', str(msg))}]"
                    # keep looping on known noise types
                except asyncio.TimeoutError:
                    continue
            return "[SparkByte did not reply within timeout]"
    except Exception as e:
        return f"[SparkByte unreachable: {e}]"

# ── Direct SparkByte tool ──────────────────────────────────────────────────────
@mcp.tool()
async def ask_sparkbyte(prompt: str) -> str:
    """Send a message directly to SparkByte and get her real reply."""
    return await _ws_ask(prompt)

# ── Dynamic Agent Tools ──────────────────────────────────────────────────────
def _register_agent_tools():
    try:
        agents = _sb("SELECT name, description FROM agents")
        for p in agents:
            p_name = p['name']
            safe_name = f"ask_agent_{''.join(c if c.isalnum() else '_' for c in p_name.lower())}"
            desc = f"Send a message to the {p_name} agent and get a real reply."[:250]

            def make_tool(agent_name):
                async def _delegate_to_agent(prompt: str) -> str:
                    return await _ws_ask(f"[From external agent, directed to {agent_name}]: {prompt}")
                _delegate_to_agent.__name__ = safe_name
                _delegate_to_agent.__doc__ = desc
                return _delegate_to_agent

            mcp.add_tool(make_tool(p_name), name=safe_name, description=desc)
    except Exception as e:
        print(f"[sparkbyte-mcp] agent tool registration skipped: {e}", file=sys.stderr, flush=True)

_register_agent_tools()

# ── Transport selector ────────────────────────────────────────────────────────
if __name__ == "__main__":
    if _USE_HTTP:
        print(f"[JL-SB-Omni MCP] SSE mode → http://{_MCP_HOST}:{_MCP_PORT}/sse", flush=True)
        mcp.run(transport="sse")
    else:
        mcp.run(transport="stdio")
