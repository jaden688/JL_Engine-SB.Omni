# Hacker News — Show HN Post

---

**Title:**
Show HN: SparkByte – Julia AI agent engine with self-forging tools and MCP/A2A bridge

---

**Body:**

Hi HN,

I've been building SparkByte, a Julia-native AI agent engine that takes a different approach to agent frameworks. Instead of just chaining prompts and tools, it models the conversation as a behavioral state machine before the LLM ever sees the message.

**What makes it different:**

- **Behavioral middleware**: Every turn passes through SignalScorer -> BehaviorStateMachine (20 named states on a 5x4 grid) -> DriftPressure -> RhythmEngine -> EmotionalAperture. The engine decides intensity, cadence, and temperature dynamically per turn.

- **Self-forging tools**: The agent can call `forge_new_tool(name, code, description)` which evals Julia code live, tests it, and persists it. No restart needed. SparkByte regularly extends her own capabilities at runtime.

- **Real tools, not sandboxed**: File I/O, shell commands, Playwright browser automation, GitHub repo intelligence, SMS, Discord, Bluetooth — actual OS-level access.

- **MCP bridge**: Any MCP-compatible client (Claude Code, Cursor, Gemini CLI) can discover and query the engine's state, memory, tools, and thoughts via stdio server.

- **A2A protocol**: Full Agent-to-Agent HTTP endpoint with JSON-RPC 2.0, task lifecycle, auth, rate limiting, usage metering, and Stripe billing integration.

- **Multi-backend**: Works with Ollama (local), Google Gemini, OpenAI, Cerebras, xAI, or any OpenAI-compatible endpoint. Not locked to any provider.

- **5 agents**: Each with distinct emotional palettes, drive types, and behavioral profiles. Switchable at runtime.

**Tech stack**: Julia (engine core + BYTE agentic loop + A2A server), Python (MCP bridge + JulianMetaMorph GitHub intelligence), SQLite (memory + tools + telemetry), WebSocket (browser UI), Docker ready.

**Quick start**:
```
git clone https://github.com/jaden688/JL_Engine-SB.Omni
cd JL_Engine-SB.Omni
cp .env.example .env
julia sparkbyte.jl
```

Or `docker compose up --build`. UI at localhost:8081, A2A at :8082.

I chose Julia because the behavioral middleware runs per-turn and needs to be fast. State management, signal scoring, and drift calculations are 10-100x faster than equivalent Python. The LLM call is still the bottleneck, but the engine's overhead is negligible.

The MCP/A2A integration means this isn't just a standalone toy — other agents can discover it, query it, and send it tasks via standard protocols.

Open source, MIT license. Feedback welcome.

GitHub: https://github.com/jaden688/JL_Engine-SB.Omni
Landing: https://webulacode.com
