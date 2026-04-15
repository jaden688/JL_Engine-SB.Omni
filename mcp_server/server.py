"""
SparkByte MCP Server — stdio transport, read-only, local/dev bridge, no source exposure.
Exposes live engine state, thoughts, forged tools, and Julian quarry to any MCP-compatible AI CLI.
Not the paid surface; monetize A2A instead.
"""

import sqlite3
import json
import os
import sys
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).parent.parent
SB_DB = ROOT / "sparkbyte_memory.db"
# Same monorepo layout as SparkByte: Julian quarry lives next to engine unless overridden.
_EMBEDDED_QUARRY = ROOT / "JulianMetaMorph" / "JulianMetaMorph" / "data" / "quarry.db"
JUL_DB = Path(os.environ.get("JULIAN_DB", str(_EMBEDDED_QUARRY)))
SKILL_MD = Path(os.environ.get("JULIAN_SKILL", str(Path.home() / ".claude" / "skills" / "julian" / "SKILL.md")))

mcp = FastMCP("sparkbyte")

# ── DB helpers (read-only) ─────────────────────────────────────────────────────
def _sb(query: str, params: tuple = ()) -> list[dict]:
    if not SB_DB.exists():
        return [{"error": "sparkbyte_memory.db not found — is SparkByte running?"}]
    con = sqlite3.connect(f"file:{SB_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(query, params).fetchall()
        return [dict(r) for r in rows]
    finally:
        con.close()

def _jul(query: str, params: tuple = ()) -> list[dict]:
    if not JUL_DB.exists():
        return [{"error": "quarry.db not found — is Julian running?"}]
    con = sqlite3.connect(f"file:{JUL_DB}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(query, params).fetchall()
        return [dict(r) for r in rows]
    finally:
        con.close()

# ── Resources ──────────────────────────────────────────────────────────────────
@mcp.resource("sparkbyte://skill")
def skill_context() -> str:
    """Full SparkByte/Julian project context — architecture, tools, commands, bridge."""
    if SKILL_MD.exists():
        return SKILL_MD.read_text(encoding="utf-8")
    # fallback: inline summary
    return f"""
# SparkByte / JLEngine
Julia-native AI agent engine with behavioral control layer (gait/rhythm/aperture/drift).
Root: {ROOT}
Entry: julia sparkbyte.jl | UI: http://127.0.0.1:8081

# JulianMetaMorph (joined in monorepo)
GitHub intelligence — quarry: {JUL_DB}
Entry: python -m julian_metamorph.cli | UI: http://127.0.0.1:8765
""".strip()

@mcp.resource("sparkbyte://personas")
def personas() -> str:
    """All indexed personas with their tone and boot prompt summary."""
    rows = _sb("SELECT name, tone, description, substr(boot_prompt,1,300) as boot_prompt FROM personas ORDER BY name")
    return json.dumps(rows, indent=2)

# ── Tools ──────────────────────────────────────────────────────────────────────
@mcp.tool()
def get_engine_state() -> str:
    """
    Latest SparkByte engine snapshot — gait, rhythm, aperture, behavior state,
    drift pressure, stability score, model, persona.
    """
    rows = _sb("""
        SELECT timestamp, persona, model, gait, rhythm_mode, aperture_mode,
               aperture_temp, behavior_state, behavior_expressiveness,
               drift_pressure, advisory_bias, advisory_emotional_drift, advisory_msg
        FROM turn_snapshots ORDER BY id DESC LIMIT 1
    """)
    if not rows:
        return "No turn snapshots yet — SparkByte hasn't had a conversation."
    return json.dumps(rows[0], indent=2)

@mcp.tool()
def get_thoughts(limit: int = 10, thought_type: str = "diary") -> str:
    """
    Recent SparkByte thoughts/diary entries.
    thought_type: 'diary' | 'reasoning' | 'all'
    limit: number of entries (max 50)
    """
    limit = min(limit, 50)
    if thought_type == "all":
        rows = _sb("SELECT timestamp, persona, type, mood, thought FROM thoughts ORDER BY id DESC LIMIT ?", (limit,))
    else:
        rows = _sb("SELECT timestamp, persona, type, mood, thought FROM thoughts WHERE type=? ORDER BY id DESC LIMIT ?", (thought_type, limit))
    return json.dumps(rows, indent=2)

@mcp.tool()
def list_forged_tools() -> str:
    """
    All tools SparkByte has forged at runtime — name, description, call count, last used.
    Includes both built-in and dynamically forged tools.
    """
    rows = _sb("SELECT name, description, call_count, last_used, is_dynamic, forged_at FROM tools ORDER BY call_count DESC")
    return json.dumps(rows, indent=2)

@mcp.tool()
def query_memory(tag: str = "", key: str = "", limit: int = 20) -> str:
    """
    Query SparkByte's persistent memory store.
    tag: filter by tag (e.g. 'self_src', 'self_tree', 'user_note')
    key: filter by key (partial match)
    """
    limit = min(limit, 100)
    if tag and key:
        rows = _sb("SELECT timestamp, tag, key, substr(content,1,500) as content FROM memory WHERE tag=? AND key LIKE ? ORDER BY id DESC LIMIT ?", (tag, f"%{key}%", limit))
    elif tag:
        rows = _sb("SELECT timestamp, tag, key, substr(content,1,500) as content FROM memory WHERE tag=? ORDER BY id DESC LIMIT ?", (tag, limit))
    elif key:
        rows = _sb("SELECT timestamp, tag, key, substr(content,1,500) as content FROM memory WHERE key LIKE ? ORDER BY id DESC LIMIT ?", (f"%{key}%", limit))
    else:
        rows = _sb("SELECT timestamp, tag, key, substr(content,1,200) as content FROM memory ORDER BY id DESC LIMIT ?", (limit,))
    return json.dumps(rows, indent=2)

@mcp.tool()
def get_telemetry(limit: int = 20) -> str:
    """Recent SparkByte telemetry events — what the engine has been doing."""
    limit = min(limit, 100)
    rows = _sb("SELECT timestamp, event, persona, model, turn_number FROM telemetry ORDER BY id DESC LIMIT ?", (limit,))
    return json.dumps(rows, indent=2)

@mcp.tool()
def search_julian_quarry(query: str, limit: int = 10) -> str:
    """
    Full-text search Julian's code quarry for patterns/implementations.
    Returns file hits with repo, path, language, license, score, and why.
    """
    limit = min(limit, 30)
    try:
        rows = _jul("""
            SELECT r.full_name AS repo_full_name,
                   f.path AS file_path,
                   f.language,
                   r.license_spdx,
                   bm25(files_fts) AS score,
                   snippet(files_fts, 4, '', '', ' ... ', 20) AS preview,
                   snippet(files_fts, 4, '', '', ' ... ', 20) AS why,
                   substr(f.symbols_json, 1, 200) AS symbols,
                   r.allowed AS allowed
            FROM files_fts
            JOIN files f ON f.id = files_fts.rowid
            JOIN repos r ON r.full_name = f.repo_full_name
            WHERE files_fts MATCH ?
            ORDER BY score
            LIMIT ?
        """, (query, limit))
        if not rows:
            # Fallback for partial or older quarries without the FTS index.
            rows = _jul("""
                SELECT r.full_name AS repo_full_name,
                       f.path AS file_path,
                       f.language,
                       r.license_spdx,
                       0.0 AS score,
                       substr(f.content, 1, 300) AS preview,
                       substr(f.content, 1, 300) AS why,
                       substr(f.symbols_json, 1, 200) AS symbols,
                       r.allowed AS allowed
                FROM files f
                JOIN repos r ON r.full_name = f.repo_full_name
                WHERE f.content LIKE ? OR f.path LIKE ?
                ORDER BY f.updated_at DESC
                LIMIT ?
            """, (f"%{query}%", f"%{query}%", limit))
    except sqlite3.OperationalError as exc:
        rows = [{"error": f"Julian quarry search failed: {exc}"}]
    return json.dumps(rows, indent=2)

@mcp.tool()
def get_knowledge(domain: str = "", limit: int = 20) -> str:
    """
    Query SparkByte's knowledge base.
    domain: 'engine_capabilities' | 'tool_schema' | 'engine_framework' | '' for all
    """
    limit = min(limit, 50)
    if domain:
        rows = _sb("SELECT domain, topic, substr(content,1,400) as content, source FROM knowledge WHERE domain=? LIMIT ?", (domain, limit))
    else:
        rows = _sb("SELECT domain, topic, substr(content,1,200) as content, source FROM knowledge ORDER BY id DESC LIMIT ?", (limit,))
    return json.dumps(rows, indent=2)

# ── Dynamic Persona Tools ──────────────────────────────────────────────────────
def _register_persona_tools():
    try:
        personas = _sb("SELECT name, description FROM personas")
        for p in personas:
            p_name = p['name']
            safe_name = f"ask_persona_{''.join(c if c.isalnum() else '_' for c in p_name.lower())}"
            desc = f"Delegate a task to the {p_name} persona. {p.get('description', '')}"[:250]

            def make_tool(persona_name):
                def _delegate_to_persona(prompt: str) -> str:
                    f"Send a prompt to {persona_name}."
                    return f"Task dispatched to {persona_name}: {prompt}"
                _delegate_to_persona.__name__ = safe_name
                _delegate_to_persona.__doc__ = desc
                return _delegate_to_persona

            mcp.add_tool(make_tool(p_name), name=safe_name, description=desc)
    except Exception as e:
        print(f"Failed to load dynamic persona tools: {e}", file=sys.stderr)

_register_persona_tools()

# ── Entry ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    mcp.run(transport="stdio")
