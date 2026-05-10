#!/usr/bin/env bash
set -euo pipefail

SPARKBYTE_URL="${SPARKBYTE_URL:-http://127.0.0.1:${SPARKBYTE_PUBLIC_PORT:-8081}}"
A2A_URL="${A2A_URL:-http://127.0.0.1:${A2A_PUBLIC_PORT:-8082}}"
TIMEOUT="${SMOKE_TIMEOUT_SECONDS:-15}"

check_json() {
  local name="$1"
  local url="$2"
  echo "[smoke] ${name}: ${url}"
  curl --fail --silent --show-error --max-time "${TIMEOUT}" "${url}" >/tmp/jl-engine-smoke.json
  python -m json.tool /tmp/jl-engine-smoke.json >/dev/null
}

check_json "SparkByte health" "${SPARKBYTE_URL}/health"
check_json "A2A health" "${A2A_URL}/health"
check_json "A2A agent card" "${A2A_URL}/.well-known/agent.json"

rm -f /tmp/jl-engine-smoke.json
echo "[smoke] OK"
