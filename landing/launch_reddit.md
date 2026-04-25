# Reddit Launch Posts — Tailored per subreddit

---

## r/LocalLLaMA

**Title:** I built a local AI agent engine in Julia with self-forging tools, behavioral state machine, and MCP bridge

**Body:**

Been working on SparkByte — a Julia-native agent engine that takes a different approach from LangChain/CrewAI/AutoGen.

Instead of just prompt chaining, it runs a behavioral state machine every turn: signal scoring, drift pressure, rhythm control, and emotional aperture adjustment — all before the LLM sees your message. The result is agents that actually feel different from each other, not just different system prompts.

**Why it matters for local LLM users:**

- Works with **Ollama** out of the box (default: qwen3:4b). Also supports Gemini, OpenAI, Cerebras, xAI, or any OpenAI-compatible endpoint.
- The behavioral layer means even smaller models produce more consistent, agent-driven responses.
- **forge_new_tool** lets the agent write and eval Julia tools at runtime — no restart needed. Your agent builds its own capabilities.
- Real tools: file I/O, shell, Playwright browser, GitHub scraping, SMS, Discord.
- MCP bridge so Claude Code / Cursor can query your local engine.
- A2A protocol for agent-to-agent communication.
- Fully local. SQLite for everything. Docker ready.

```
git clone https://github.com/jaden688/JL_Engine-SB.Omni
julia sparkbyte.jl   # UI at localhost:8081
```

Open source, MIT. Feedback appreciated.

GitHub: https://github.com/jaden688/JL_Engine-SB.Omni

---

## Automation Note

The SparkByte engine now has a `reddit_submit` tool for pushing one of these posts to Reddit.

Recommended flow:

1. Run a dry run first with `dry_run=true`.
2. Set `REDDIT_SUBREDDIT`, `REDDIT_USER_AGENT`, and either `REDDIT_ACCESS_TOKEN` or `REDDIT_CLIENT_ID` + `REDDIT_REFRESH_TOKEN`.
3. Submit the chosen `title` and `text` with `kind="self"` for launch posts.

---

## r/JuliaLang

**Title:** SparkByte: An AI agent engine built entirely in Julia — behavioral state machine, live tool forging, MCP/A2A protocols

**Body:**

Wanted to share a project I've been building in Julia. SparkByte is an AI agent engine where the core behavioral middleware is pure Julia:

- **SignalScorer** — scores user messages for sentiment, arousal, directive intent, confusion, pace
- **BehaviorStateMachine** — 5x4 grid of named states controlling expressiveness, pacing, tone bias
- **DriftPressureSystem** — tracks agent alignment drift (0.0-1.0)
- **RhythmEngine** — flip/flop/trot cadence modes
- **EmotionalAperture** — dynamically sets LLM temperature/top_p per turn
- **HybridMemorySystem** — SQLite-backed with breadcrumbs, intent tracking, interaction history

The most interesting Julia-specific feature: **forge_new_tool**. The agent can write a Julia function, and the engine evals it live with `Base.invokelatest`, tests it, and persists it to a registry. No restart. The tool is immediately available in the dispatch loop.

The engine uses HTTP.jl for the A2A (Agent-to-Agent) JSON-RPC server, SQLite.jl for all persistence, and a WebSocket-based browser UI.

I chose Julia because the behavioral middleware runs per-turn and needs sub-millisecond overhead. Signal scoring and state transitions are essentially hot-path computations that benefit from Julia's speed.

Would love feedback from the Julia community, especially around:
- Better patterns for the live eval + persist workflow
- HTTP.jl patterns for production-grade servers
- SQLite.jl concurrency considerations

GitHub: https://github.com/jaden688/JL_Engine-SB.Omni

---

## r/SideProject

**Title:** I built an AI agent engine that forges its own tools at runtime — now making it a business

**Body:**

SparkByte is a Julia-native AI agent engine I've been building. Unlike typical agent wrappers, it has a behavioral state machine that controls how the agent responds — mood, intensity, cadence, creativity — all computed per turn.

The killer feature: the agent can write, test, and deploy new tools to itself at runtime. No restart. It's shipped with 14 tools and has built more on its own.

It already speaks MCP (so Claude Code, Cursor, etc. can talk to it) and A2A (Agent-to-Agent protocol for task routing).

**Going commercial:**
- Free: full local engine, open source
- Pro ($29/mo): hosted, always-on, cloud memory, read/write MCP bridge
- Enterprise ($199/seat/mo): teams, SSO, dedicated instances

Landing page: https://webulacode.com
GitHub: https://github.com/jaden688/JL_Engine-SB.Omni

Would love feedback on the product positioning. The MCP/agent runtime market is moving fast and I'm trying to find the right wedge.
