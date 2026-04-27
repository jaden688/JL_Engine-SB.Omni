"""
SparkByte MCP Server — dual transport.

Run modes:
  stdio (default):  python server.py
  SSE:              python server.py --http      (uses MCP_PORT, default 8083)
  Streamable-HTTP:  python http_server.py        (FastMCP default, port 8000)

Security posture:
  - Default bind is 127.0.0.1. Binding to a non-loopback address requires
    MCP_BIND_ACK=I_understand_no_builtin_auth and an MCP_AUTH_TOKEN. The
    server enforces a Bearer-token check on HTTP/SSE in that case.
  - All filesystem inputs (JULIAN_DB, JULIAN_SKILL) must resolve under an
    allow-listed root unless MCP_ALLOW_EXTERNAL_PATHS=1.
  - SPARKBYTE_WS must be loopback unless MCP_ALLOW_REMOTE_WS=1.
  - WS round-trips are bounded by a semaphore (MCP_WS_CONCURRENCY, default 4).
  - Tool outputs are capped at MCP_MAX_RESPONSE_BYTES (default 60kB).

Environment knobs (all optional):
  MCP_TRANSPORT             stdio|sse|http       (default stdio)
  MCP_PORT                  int                   (default 8083)
  MCP_BIND                  ip                    (default 127.0.0.1)
  MCP_BIND_ACK              "I_understand_no_builtin_auth" to allow non-loopback
  MCP_AUTH_TOKEN            shared secret required for non-loopback HTTP/SSE
  MCP_ALLOW_EXTERNAL_PATHS  1 to skip path-sandbox checks
  MCP_ALLOW_REMOTE_WS       1 to permit non-loopback SPARKBYTE_WS
  MCP_MAX_RESPONSE_BYTES    int                   (default 60000)
  MCP_WS_CONCURRENCY        int                   (default 4)
  SPARKBYTE_WS              ws URL                (default ws://127.0.0.1:8081)
  SPARKBYTE_WS_TIMEOUT      seconds               (default 60)
  JULIAN_DB                 path to quarry.db
  JULIAN_SKILL              path to SKILL.md
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sqlite3
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import websockets
from mcp.server.fastmcp import FastMCP

# ── Logging ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=os.environ.get("MCP_LOG_LEVEL", "INFO"),
    format="%(asctime)s [sparkbyte-mcp] %(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("sparkbyte-mcp")

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).resolve().parent.parent
SB_DB = ROOT / "sparkbyte_memory.db"

_ALLOW_EXTERNAL_PATHS = os.environ.get("MCP_ALLOW_EXTERNAL_PATHS") == "1"
_ALLOWED_ROOTS = [ROOT.resolve(), Path.home().resolve()]


def _safe_path(raw: str, label: str) -> Path:
    """Resolve a path and ensure it's under an allow-listed root (unless opted out)."""
    p = Path(raw).expanduser().resolve()
    if _ALLOW_EXTERNAL_PATHS:
        return p
    for root in _ALLOWED_ROOTS:
        try:
            p.relative_to(root)
            return p
        except ValueError:
            continue
    raise ValueError(
        f"{label}={raw!r} resolves to {p} which is outside allowed roots "
        f"({[str(r) for r in _ALLOWED_ROOTS]}). Set MCP_ALLOW_EXTERNAL_PATHS=1 to override."
    )


_EMBEDDED_QUARRY = ROOT / "JulianMetaMorph" / "JulianMetaMorph" / "data" / "quarry.db"
JUL_DB = _safe_path(os.environ.get("JULIAN_DB", str(_EMBEDDED_QUARRY)), "JULIAN_DB")
SKILL_MD = _safe_path(
    os.environ.get("JULIAN_SKILL", str(Path.home() / ".claude" / "skills" / "julian" / "SKILL.md")),
    "JULIAN_SKILL",
)

# ── Network config ─────────────────────────────────────────────────────────────
_MCP_PORT = int(os.environ.get("MCP_PORT", "8083"))
_USE_HTTP = "--http" in sys.argv or os.environ.get("MCP_TRANSPORT", "").lower() in ("sse", "http")
_MCP_BIND = os.environ.get("MCP_BIND", "127.0.0.1")
_BIND_ACK = os.environ.get("MCP_BIND_ACK", "")
_AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN", "")

_LOOPBACK = {"127.0.0.1", "localhost", "::1"}
_NON_LOOPBACK = _MCP_BIND not in _LOOPBACK

if _USE_HTTP and _NON_LOOPBACK:
    if _BIND_ACK != "I_understand_no_builtin_auth":
        log.error(
            "Refusing to bind %s without MCP_BIND_ACK=I_understand_no_builtin_auth. "
            "Either bind 127.0.0.1 or set the ack and front this server with TLS+auth.",
            _MCP_BIND,
        )
        sys.exit(2)
    if not _AUTH_TOKEN or len(_AUTH_TOKEN) < 16:
        log.error("Non-loopback bind requires MCP_AUTH_TOKEN (>=16 chars).")
        sys.exit(2)

_MAX_BYTES = int(os.environ.get("MCP_MAX_RESPONSE_BYTES", "60000"))
_WS_TIMEOUT = float(os.environ.get("SPARKBYTE_WS_TIMEOUT", "60"))
_WS_CONCURRENCY = max(1, int(os.environ.get("MCP_WS_CONCURRENCY", "4")))
_SB_WS = os.environ.get("SPARKBYTE_WS", "ws://127.0.0.1:8081")

_ws_parsed = urlparse(_SB_WS)
if _ws_parsed.hostname not in _LOOPBACK and os.environ.get("MCP_ALLOW_REMOTE_WS") != "1":
    log.error("SPARKBYTE_WS=%s is non-loopback. Set MCP_ALLOW_REMOTE_WS=1 to allow.", _SB_WS)
    sys.exit(2)

_ws_semaphore: asyncio.Semaphore | None = None  # lazy-init inside running loop

# ── Output capping ─────────────────────────────────────────────────────────────
def _cap(payload: str, kind: str = "result") -> str:
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


def _err(msg: str, **extra) -> str:
    return json.dumps({"ok": False, "error": msg, **extra})


# ── FastMCP instance ───────────────────────────────────────────────────────────
mcp = FastMCP("sparkbyte", host=_MCP_BIND, port=_MCP_PORT)


# ── DB helpers ─────────────────────────────────────────────────────────────────
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


def _clamp(n, lo: int, hi: int) -> int:
    try:
        n = int(n)
    except Exception:
        n = lo
    return max(lo, min(n, hi))


# ── Tools ──────────────────────────────────────────────────────────────────────
@mcp.tool()
def get_engine_state() -> str:
    """Latest SparkByte engine snapshot."""
    rows = _sb("SELECT * FROM turn_snapshots ORDER BY id DESC LIMIT 1")
    return json.dumps(rows[0] if rows else "No data", indent=2)


@mcp.tool()
def list_forged_tools() -> str:
    """List runtime-forged tools recorded in the SQLite tools table."""
    rows = _sb("SELECT name, description, call_count FROM tools ORDER BY call_count DESC")
    return json.dumps(rows, indent=2)


@mcp.tool()
def query_memory(tag: str = "", key: str = "", limit: int = 20) -> str:
    """Query persistent memory. Output capped at MCP_MAX_RESPONSE_BYTES."""
    limit = _clamp(limit, 1, 200)
    rows = _sb(
        "SELECT tag, key, content FROM memory WHERE tag LIKE ? AND key LIKE ? LIMIT ?",
        (f"%{tag}%", f"%{key}%", limit),
    )
    return _cap(json.dumps(rows, indent=2), kind="memory")


@mcp.tool()
def get_recent_telemetry(limit: int = 20) -> str:
    """Recent telemetry events."""
    limit = _clamp(limit, 1, 500)
    rows = _sb(
        "SELECT event, jl_agent, turn_number FROM telemetry ORDER BY id DESC LIMIT ?",
        (limit,),
    )
    return json.dumps(rows, indent=2)


@mcp.tool()
def write_memory(tag: str, key: str, content: str) -> str:
    """Persist a memory entry (tag, key, content) into sparkbyte_memory.db."""
    if not SB_DB.exists():
        return _err("sparkbyte_memory.db not found")
    if not tag or not key:
        return _err("tag and key are required")
    if len(content) > 100_000:
        return _err("content exceeds 100kB limit")
    con = sqlite3.connect(SB_DB)
    try:
        con.execute(
            "INSERT INTO memory (timestamp, tag, key, content) VALUES (?, ?, ?, ?)",
            (datetime.now(timezone.utc).isoformat(), tag, key, content),
        )
        con.commit()
        return json.dumps({"ok": True, "tag": tag, "key": key})
    except sqlite3.Error as e:
        return _err(f"sqlite: {e}")
    finally:
        con.close()


@mcp.tool()
def list_forged_tools_registry() -> str:
    """List forged tools from dynamic_tools_registry.json (Julia runtime)."""
    reg = ROOT / "dynamic_tools_registry.json"
    if not reg.exists():
        return _err("dynamic_tools_registry.json not found")
    return _cap(reg.read_text(encoding="utf-8", errors="replace"), kind="forged_registry")


@mcp.tool()
def list_agents() -> str:
    """List registered SparkByte agents (name, tone, active flag)."""
    rows = _sb("SELECT name, description, tone, active FROM agents ORDER BY name")
    return json.dumps(rows, indent=2)


@mcp.tool()
def search_julian_quarry(query: str, limit: int = 10) -> str:
    """Search Julian's code quarry by content substring."""
    limit = _clamp(limit, 1, 50)
    if not query or len(query) < 2:
        return _err("query must be at least 2 chars")
    rows = _jul(
        "SELECT repo_full_name, file_path, language FROM files WHERE content LIKE ? LIMIT ?",
        (f"%{query}%", limit),
    )
    return _cap(json.dumps(rows, indent=2), kind="quarry")


# ── WebSocket round-trip ──────────────────────────────────────────────────────
_PROMPT_INJECTION_PATTERNS = re.compile(r"[\x00-\x08\x0b-\x1f]|(\[SYSTEM[^\]]*\])", re.IGNORECASE)


def _sanitize_for_prompt(s: str, max_len: int = 4000) -> str:
    """Strip control chars and any [SYSTEM ...] markers a caller might inject."""
    s = _PROMPT_INJECTION_PATTERNS.sub("", str(s))
    return s[:max_len]


async def _ws_ask(prompt: str, timeout: float | None = None) -> str:
    """Async WS call to SparkByte — round-trips one chat message and returns the spark reply."""
    REPLY_TYPES = {"spark"}
    ERROR_TYPES = {"error"}
    if timeout is None:
        timeout = _WS_TIMEOUT

    global _ws_semaphore
    if _ws_semaphore is None:
        _ws_semaphore = asyncio.Semaphore(_WS_CONCURRENCY)

    started = time.monotonic()
    async with _ws_semaphore:
        try:
            async with websockets.connect(_SB_WS, open_timeout=5) as ws:
                payload = json.dumps({"type": "chat", "text": prompt, "id": str(uuid.uuid4())})
                await ws.send(payload)
                loop = asyncio.get_running_loop()
                deadline = loop.time() + timeout
                while loop.time() < deadline:
                    try:
                        raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
                        msg = json.loads(raw)
                        mtype = msg.get("type", "")
                        if mtype in REPLY_TYPES:
                            log.info("ws_ask ok in %.2fs", time.monotonic() - started)
                            return msg.get("text") or msg.get("content") or msg.get("message") or str(msg)
                        if mtype in ERROR_TYPES:
                            return f"[SparkByte error: {msg.get('text', str(msg))}]"
                    except asyncio.TimeoutError:
                        continue
                return "[SparkByte did not reply within timeout]"
        except Exception as e:
            log.warning("ws_ask failed: %s", e)
            return f"[SparkByte unreachable: {e}]"


@mcp.tool()
async def ask_sparkbyte(prompt: str) -> str:
    """Send a message to SparkByte and get her real reply."""
    return await _ws_ask(_sanitize_for_prompt(prompt))


@mcp.tool()
async def call_forged_tool(name: str, args: dict | None = None) -> str:
    """Invoke a Julia-runtime forged tool (see list_forged_tools_registry) via SparkByte."""
    safe_name = re.sub(r"[^A-Za-z0-9_]", "", str(name))[:64]
    if not safe_name:
        return _err("invalid tool name")
    try:
        args_json = json.dumps(args or {})
    except (TypeError, ValueError) as e:
        return _err(f"args not JSON-serialisable: {e}")
    prompt = (
        f"[SYSTEM TOOL CALL] Invoke forged tool `{safe_name}` with args {args_json}. "
        f"Return ONLY the raw tool result, no commentary."
    )
    return await _ws_ask(prompt)


# ── Dynamic per-agent tools ────────────────────────────────────────────────────
def _register_agent_tools() -> int:
    count = 0
    try:
        agents = _sb("SELECT name, description FROM agents")
    except Exception as e:
        log.warning("agent registration: cannot read agents table: %s", e)
        return 0

    seen: set[str] = set()
    for p in agents:
        p_name = p.get("name") if isinstance(p, dict) else None
        if not p_name:
            continue
        slug = re.sub(r"[^a-z0-9_]", "_", p_name.lower())
        safe_name = f"ask_agent_{slug}"
        # de-dup collisions
        base = safe_name
        i = 2
        while safe_name in seen:
            safe_name = f"{base}_{i}"
            i += 1
        seen.add(safe_name)
        desc = f"Send a message to the {p_name} agent and get a real reply."[:250]

        def make_tool(agent_name: str, _name: str = safe_name):
            async def _delegate(prompt: str) -> str:
                clean = _sanitize_for_prompt(prompt)
                return await _ws_ask(f"[From external caller, directed to {agent_name}]: {clean}")
            _delegate.__name__ = _name
            _delegate.__doc__ = desc
            return _delegate

        try:
            mcp.add_tool(make_tool(p_name), name=safe_name, description=desc)
            count += 1
        except Exception as e:
            log.warning("failed to register %s: %s", safe_name, e)
    log.info("registered %d agent passthrough tools", count)
    return count


_register_agent_tools()


# ── Auth middleware (HTTP/SSE only) ────────────────────────────────────────────
def _wrap_with_auth(app):
    """Wrap an ASGI app with a Bearer-token check when MCP_AUTH_TOKEN is set."""
    if not _AUTH_TOKEN:
        return app

    async def asgi(scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            return await app(scope, receive, send)
        headers = dict(scope.get("headers", []))
        auth = headers.get(b"authorization", b"").decode("latin-1")
        expected = f"Bearer {_AUTH_TOKEN}"
        if auth != expected:
            if scope["type"] == "http":
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"unauthorized"})
            else:
                await send({"type": "websocket.close", "code": 4401})
            return
        return await app(scope, receive, send)

    return asgi


# ── Transport selector ────────────────────────────────────────────────────────
if __name__ == "__main__":
    if _USE_HTTP:
        log.info("SSE mode → http://%s:%s/sse  (auth: %s)",
                 _MCP_BIND, _MCP_PORT, "ON" if _AUTH_TOKEN else "OFF")
        if _AUTH_TOKEN:
            try:
                import uvicorn  # type: ignore
                app = _wrap_with_auth(mcp.sse_app())
                uvicorn.run(app, host=_MCP_BIND, port=_MCP_PORT, log_level="info")
            except ImportError:
                log.error("uvicorn not installed but MCP_AUTH_TOKEN set; install uvicorn to enable auth")
                sys.exit(2)
        else:
            mcp.run(transport="sse")
    else:
        mcp.run(transport="stdio")
