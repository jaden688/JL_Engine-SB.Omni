# Security Policy — JL Engine / SparkByte Omni

## Supported Versions

| Version / Branch | Supported |
|---|---|
| `main` (latest) | ✅ Active |
| `legacy/` archives | ❌ Not supported |

Security fixes are applied to `main` only. No backport policy exists at this time.

---

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

To report a vulnerability privately:

1. Use [GitHub's private vulnerability reporting](https://github.com/jaden688/JL_Engine-SB.Omni/security/advisories/new) (preferred).
2. Or email the repository owner directly via the contact listed on their GitHub profile.

Include in your report:
- A clear description of the vulnerability
- Steps to reproduce (proof-of-concept code if applicable)
- Affected component(s): BYTE engine, A2A server, MCP server, Tools, etc.
- Assessed impact (confidentiality, integrity, availability)

**Response target:** acknowledgement within 7 days, remediation assessment within 14 days.

---

## Threat Model & Attack Surface

JL Engine has several surfaces with distinct risk profiles:

### 1. WebSocket Server — Port 8081 (BYTE)
- Serves the UI and accepts all user/agent chat commands.
- **No built-in auth by default.** Intended for `127.0.0.1` loopback only.
- **Risk:** Any process or user on the host can connect and execute tools.
- **Mitigation:** `SPARKBYTE_HOST=127.0.0.1` (default). Never bind to `0.0.0.0` without a reverse proxy with authentication (e.g., nginx + Basic Auth, Cloudflare Tunnel).

### 2. A2A JSON-RPC Server — Port 8082
- Exposes the engine to external agents over HTTP.
- **Bearer auth required** (`A2A_API_KEY`). Fail-closed: blank env returns 503 unless `A2A_ALLOW_PUBLIC=true`.
- Separate admin key (`A2A_ADMIN_KEY`) required for billing mutation RPC methods.
- Rate limiting: `A2A_MAX_REQUESTS_PER_MINUTE` (defaults to 0 = off; enable in production).
- **Risk:** Without a strong `A2A_API_KEY`, any caller can invoke agent tasks and consume LLM credits.
- **Mitigation:** Always set `A2A_API_KEY` and `A2A_ADMIN_KEY` before internet exposure. Rotate keys via `billing/key/create`.

### 3. MCP Server — Port 8083 (Python)
- Two transports: stdio (Claude Desktop) and streamable-HTTP.
- Bearer auth on HTTP transport (`MCP_AUTH_TOKEN`, min 16 chars).
- Refuses non-loopback bind without explicit opt-in (`MCP_BIND_ACK`).
- Path sandbox: all filesystem paths resolve under repo root or `$HOME`.
- Prompt-injection sanitization: strips control characters and `[SYSTEM ...]` markers.
- Concurrency cap via `asyncio.Semaphore`.
- Output truncation via `MCP_MAX_RESPONSE_BYTES`.
- **Risk:** MCP write tools (`write_memory`, `ask_sparkbyte`, `call_forged_tool`) can modify engine state.
- **Mitigation:** Always set `MCP_AUTH_TOKEN` for the HTTP transport. Run smoke tests (`python mcp_server/smoke_test.py`) after any MCP changes.

### 4. High-Risk Tools (Code Execution)

These tools execute arbitrary code on the host and represent the highest-risk surface:

| Tool | Risk | Notes |
|---|---|---|
| `run_command` | **Critical** — arbitrary shell execution | Intended for local dev; disable or sandbox in production |
| `execute_code` (Julia + Python) | **Critical** — arbitrary code execution | Same as above |
| `forge_new_tool` | **Critical** — live `Base.eval` of LLM-generated Julia into the BYTE module | Forged tools persist to `dynamic_tools.jl` and load on next boot |
| `write_file` | **High** — arbitrary file write to host FS | Scoped by path sandbox in MCP; no sandbox in native BYTE tools |
| `browse_url` / stealth browser | **Medium** — SSRF, data exfiltration via Playwright | Avoid allowing URLs from untrusted input in production |
| `github_pillage` | **Medium** — reads GitHub repo content | Requires `GITHUB_TOKEN`; token scope should be read-only |

**Production hardening for code-execution tools:**
- Run the engine inside a Docker container (see `Dockerfile` and `compose.yaml`).
- Use a read-only filesystem mount for the container where possible.
- Set `SPARKBYTE_TOOL_FAILURE_THRESHOLD` to auto-quarantine misbehaving forged tools.
- Review `dynamic_tools.jl` and `dynamic_tools_registry.json` regularly.

### 5. SQLite Database (`sparkbyte_memory.db`)
- Stores long-term memory (key-value), agent thought diary, full reasoning traces, and A2A accounts/usage ledger.
- Contains conversation history and may include sensitive user data.
- **Mitigation:** The file is gitignored (`*.db`). Encrypt the volume at rest in cloud deployments. Do not include the DB in container images or backups without encryption.

### 6. Telemetry Log (`full_telemetry.jsonl`)
- Structured log of every API request, tool call, token count, safety rating, and reasoning trace.
- May contain verbatim user messages and LLM responses.
- **Mitigation:** The file is gitignored (`*.jsonl`). Do not ship telemetry logs to untrusted storage. Rotate and purge on a schedule.

---

## Secrets Management

### Environment Variables
All secrets are provided via `.env` (gitignored). Never commit `.env`.

| Variable | Purpose | Risk if leaked |
|---|---|---|
| `GEMINI_API_KEY` | Google Gemini LLM access | Billing fraud |
| `OPENAI_API_KEY` | OpenAI / TTS access | Billing fraud |
| `XAI_API_KEY` | xAI Grok access | Billing fraud |
| `ANTHROPIC_API_KEY` | Anthropic Claude access | Billing fraud |
| `OPENROUTER_API_KEY` | OpenRouter routing | Billing fraud |
| `CEREBRAS_API_KEY` | Cerebras inference | Billing fraud |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI | Billing fraud |
| `A2A_API_KEY` | A2A server bearer auth | Full A2A API access |
| `A2A_ADMIN_KEY` | A2A billing admin | Billing mutation + key management |
| `STRIPE_SECRET_KEY` | Stripe payments | Financial fraud |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook validation | Payment bypass |
| `MCP_AUTH_TOKEN` | MCP HTTP server auth | Engine state read/write |
| `GITHUB_TOKEN` | GitHub API (Julian hunts) | Repo access (scope to read-only) |

**Best practices:**
- Use `.env.example` as a template; copy to `.env` and fill in secrets locally.
- In Docker/Azure, inject secrets via environment variables or a secrets manager (Azure Key Vault, Docker secrets).
- Rotate all API keys immediately if a leak is suspected.
- Scope `GITHUB_TOKEN` to the minimum required permissions (read-only for code search).
- Never log or echo secret values, even in debug output.

---

## Network Security

### Local / Development
- All servers default to `127.0.0.1` (loopback only).
- Docker Compose maps host ports; review `compose.yaml` before exposing to LAN.

### Production / Cloud (Azure Container Apps)
- Place the WebSocket server (8081) behind a reverse proxy with authentication.
- Use TLS termination at the load balancer; do not run plaintext HTTP over the internet.
- Set `A2A_PUBLIC_URL` to your HTTPS public hostname.
- Restrict inbound traffic with Azure network security groups or Cloudflare Access.
- Enable rate limiting: `A2A_MAX_REQUESTS_PER_MINUTE`.

### Docker
- The `Dockerfile` runs as a non-root user (verify with `USER` directive after base image updates).
- Do not expose debug or admin ports (`8082`, `8083`) publicly unless required.
- Review `.dockerignore` to ensure no secrets are copied into the image layer.

---

## Dependency Security

- **Julia packages:** listed in `Project.toml`. Run `julia -e 'using Pkg; Pkg.update()'` periodically to get patched versions.
- **Python (MCP server):** listed in `mcp_server/requirements.txt`. Run `pip install --upgrade -r mcp_server/requirements.txt`.
- **Node.js (web/):** listed in `web/package.json`. Run `npm audit` and `npm audit fix` regularly. There are currently 8 moderate + 2 low Dependabot alerts — review and remediate.
- **GitHub Actions:** Dependabot is configured; review and merge security PRs promptly.

---

## Known Security Gaps

| Gap | Status | Workaround |
|---|---|---|
| No Stripe webhook wired | ⚠️ Open | Admin must manually call `billing/key/update` after payment |
| `run_command` / `execute_code` have no sandbox in BYTE tools layer | ⚠️ Open | Run inside Docker; review forged tools before use |
| WebSocket server (8081) has no built-in auth | ⚠️ Open | Keep bound to loopback or add a reverse proxy with auth |
| Julia test suite not green on CI | ⚠️ Open | `continue-on-error: true` on julia job; fix in progress |
| 8 moderate + 2 low Dependabot alerts (web/) | ⚠️ Open | Run `npm audit fix` in `web/` |

---

## Security Hardening Checklist (Production Deployments)

- [ ] Set strong random values for `A2A_API_KEY`, `A2A_ADMIN_KEY`, and `MCP_AUTH_TOKEN`
- [ ] Bind all servers to loopback or private network, never `0.0.0.0` without a reverse proxy
- [ ] Enable TLS at the load balancer / reverse proxy
- [ ] Set `A2A_MAX_REQUESTS_PER_MINUTE` to a sensible limit
- [ ] Set `A2A_BILLING_ENFORCE=true` to require subscription for A2A tasks
- [ ] Run inside Docker with a minimal image; review `.dockerignore`
- [ ] Mount `sparkbyte_memory.db` and `full_telemetry.jsonl` on an encrypted volume
- [ ] Scope `GITHUB_TOKEN` to read-only permissions
- [ ] Review `dynamic_tools.jl` on every boot (forged tools from prior sessions)
- [ ] Run `npm audit` in `web/` and resolve all high/critical findings
- [ ] Enable Dependabot alerts and auto-merge for security patches in GitHub Settings
- [ ] Rotate all API keys on a schedule (e.g., 90 days)
- [ ] Purge or archive `full_telemetry.jsonl` on a regular schedule

---

*This document was last updated: 2026-05-03*
