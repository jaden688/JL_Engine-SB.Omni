"""One-shot: purge the word 'agent' from source files.
Skips: .db, .sqlite, .jsonl, binary, node_modules, .git, data/genome, data/quarry*.
Preserves SQL column/table 'agent' inside string literals that look like SQL
(lines containing INSERT/SELECT/CREATE TABLE) to avoid breaking live DBs.
"""
import os, re, sys

ROOT = r"C:\Users\J_lin\Desktop\jl-engine-reboot-reboot\JL_Engine-SB.Omni"
SKIP_DIRS = {".git", "node_modules", "genome", "quarry", "__pycache__", ".venv", "images"}
SKIP_EXT = {".db", ".sqlite", ".sqlite3", ".jsonl", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip", ".wav", ".mp3", ".mp4"}
TEXT_EXT = {".jl", ".py", ".html", ".js", ".ts", ".json", ".md", ".toml", ".yaml", ".yml", ".ps1", ".sh", ".css"}

# Order matters: longer/compound first.
REPLACEMENTS = [
    ("data/agents/", "data/agents/"),
    ("data\\\\agents\\\\", "data\\\\agents\\\\"),
    ("Agents.mpf.json", "Agents.mpf.json"),
    ("AgentManager", "AgentManager"),
    ("agentSelect", "agentSelect"),
    ("agent-select", "agent-select"),
    ("settings-agent", "settings-agent"),
    ("tl-agent-model", "tl-agent-model"),
    ("populateAgents", "populateAgents"),
    ("loadAgents", "loadAgents"),
    ("list_agents", "list_agents"),
    ("agents_list", "agents_list"),
    ("agent_change", "agent_change"),
    ("agent_alignment_score", "agent_alignment_score"),
    ("agent_vividness", "agent_vividness"),
    ("agent_projection", "agent_projection"),
    ("agent_memory", "agent_memory"),
    ("agent_store", "agent_store"),
    ("agent_state", "agent_state"),
    ("agent_manager", "agent_manager"),
    ("load_agent_file", "load_agent_file"),
    ("set_agent_state!", "set_agent_state!"),
    ("set_active_agent!", "set_active_agent!"),
    ("set_agent!", "set_agent!"),
    ("get_agent", "get_agent"),
    ("last_active_agent", "last_active_agent"),
    ("log_agent_change", "log_agent_change"),
    ("current_agent_name", "current_agent_name"),
    ("current_agent_data", "current_agent_data"),
    ("current_agent_file", "current_agent_file"),
    ("default_agent_name", "default_agent_name"),
    ("agents_dir", "agents_dir"),
    ("agent_file", "agent_file"),
    ("agent_name", "agent_name"),
    ("engine_agent", "engine_agent"),
    ("ACTIVE JL AGENT", "ACTIVE JL AGENT"),
    ("Active JL Agent", "Active JL Agent"),
    ("active JL agent", "active JL agent"),
    ("JL AGENT ·", "JL AGENT ·"),
    ("a JL agent", "a JL agent"),
    ("the JL agent", "the JL agent"),
    ("Agent registry", "Agent registry"),
    ("agent registry", "agent registry"),
    ("in character", "in character"),
    ("Agents", "Agents"),  # generic fallback for Title-cased
    ("agents", "agents"),  # generic fallback for lowercase
    ("Agent", "Agent"),
    ("agent", "agent"),
]

# Inside SQL-looking lines, preserve the literal column/table name 'agent' / 'agents'.
# Heuristic: line contains one of these SQL keywords AND the column 'agent' appears as a bareword.
SQL_MARKERS = ("INSERT INTO", "SELECT ", "CREATE TABLE", "UPDATE ", "DELETE FROM", "FROM personas", "FROM telemetry", "FROM thoughts", "FROM tool_usage_log", "ALTER TABLE")

def is_sql_line(line: str) -> bool:
    return any(m in line for m in SQL_MARKERS)

def should_skip(path: str) -> bool:
    parts = set(path.replace("\\", "/").split("/"))
    if parts & SKIP_DIRS:
        return True
    ext = os.path.splitext(path)[1].lower()
    if ext in SKIP_EXT:
        return True
    if ext and ext not in TEXT_EXT:
        return True
    return False

def process_file(path: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as f:
            original = f.read()
    except UnicodeDecodeError:
        return 0
    out_lines = []
    changes = 0
    for line in original.splitlines(keepends=True):
        new_line = line
        if is_sql_line(line):
            # Only do replacements that don't touch bareword "agent" / "agents".
            for a, b in REPLACEMENTS:
                if a in ("agent", "Agent", "agents", "Agents"):
                    continue
                if a in new_line:
                    new_line = new_line.replace(a, b)
        else:
            for a, b in REPLACEMENTS:
                if a in new_line:
                    new_line = new_line.replace(a, b)
        if new_line != line:
            changes += 1
        out_lines.append(new_line)
    if changes:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.writelines(out_lines)
    return changes

total_files = 0
total_changes = 0
for root, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
    for name in files:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, ROOT)
        if should_skip(rel):
            continue
        c = process_file(path)
        if c:
            total_files += 1
            total_changes += c
            print(f"  {rel}: {c} lines")

print(f"\nTotal: {total_files} files, {total_changes} lines changed")
