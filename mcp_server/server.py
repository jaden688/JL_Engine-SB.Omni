"""
SparkByte MCP Server — stdio transport, read-only, no source exposure.
Exposes live engine state, thoughts, forged tools, and Julian quarry to any MCP-compatible AI CLI.
"""

import sqlite3
import json
import os
import sys
from pathlib import Path
from mcp.server.fastmcp import FastMCP

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).parent.parent
SB_DB   = ROOT / "sparkbyte_memory.db"
JUL_DB  = Path(os.environ.get("JULIAN_DB", r"C:\Users\J_lin\Desktop\JulianMetaMorph\JulianMetaMorph\data\quarry.db"))
SKILL_MD = Path(os.environ.get("JULIAN_SKILL", r"C:\Users\J_lin\.claude\skills\julian\SKILL.md"))

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
    return """
# SparkByte / JLEngine
Julia-native AI agent engine with behavioral control layer (gait/rhythm/aperture/drift).
Root: C:\\Users\\J_lin\\Desktop\\JL_Engine (3)\\jl-vs\\vscode-main\\copilot-separate-leopard
Entry: julia sparkbyte.jl | UI: http://127.0.0.1:8081

# JulianMetaMorph
GitHub intelligence engine — hunts repos, forges Python skill modules.
Root: C:\\Users\\J_lin\\Desktop\\JulianMetaMorph\\JulianMetaMorph
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
    rows = _jul("""
        SELECT f.repo_full_name, f.file_path, f.language, f.license_spdx,
               h.score, h.category, h.why, substr(h.symbols_json,1,200) as symbols
        FROM hits h
        JOIN files f ON h.file_id = f.id
        WHERE h.why LIKE ? OR f.file_path LIKE ?
        ORDER BY h.score DESC LIMIT ?
    """, (f"%{query}%", f"%{query}%", limit))
    if not rows:
        # fallback: FTS on content
        rows = _jul("""
            SELECT f.repo_full_name, f.file_path, f.language, f.license_spdx,
                   substr(f.content,1,300) as preview
            FROM files f
            WHERE f.content LIKE ?
            ORDER BY f.id DESC LIMIT ?
        """, (f"%{query}%", limit))
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

# ── Entry ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    mcp.run(transport="stdio")
