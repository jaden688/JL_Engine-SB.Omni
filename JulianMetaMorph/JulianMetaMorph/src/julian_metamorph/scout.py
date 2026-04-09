from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from time import time

from .github_client import GitHubClient
from .license_gate import LicenseGate
from .models import RepoFile, ScoutHit
from .profile import JulianProfile
from .quarry import QuarryStore

# ── Category classification map ───────────────────────────────────────────────
# (keyword_set, category, subcategory)
_CATEGORY_RULES: list[tuple[set[str], str, str]] = [
    ({"websocket", "ws", "socket", "wss", "upgrade", "handshake"}, "websocket", "protocol"),
    ({"reconnect", "backoff", "retry", "keepalive", "heartbeat"}, "websocket", "resilience"),
    ({"stream", "chunk", "pipe", "generator", "yield", "async_gen"}, "streaming", "async_io"),
    ({"async", "await", "asyncio", "trio", "anyio", "coroutine", "event_loop"}, "streaming", "async_runtime"),
    ({"agent", "tool", "llm", "inference", "completion", "prompt", "openai", "anthropic"}, "ai_agent", "llm_tooling"),
    ({"plan", "action", "observation", "thought", "react", "chain", "workflow"}, "ai_agent", "orchestration"),
    ({"memory", "cache", "recall", "store", "retrieve", "embedding", "vector"}, "memory", "storage"),
    ({"sqlite", "database", "db", "sql", "fts", "index", "query"}, "memory", "database"),
    ({"queue", "scheduler", "pipeline", "dispatch", "broker", "task"}, "orchestration", "scheduling"),
    ({"http", "server", "router", "fastapi", "flask", "starlette", "endpoint"}, "ui_server", "http"),
    ({"html", "css", "dom", "render", "frontend", "canvas", "ui"}, "ui_server", "frontend"),
    ({"julia", "jl", "module", "mutable", "struct", "macro"}, "engine_core", "julia_patterns"),
    ({"test", "spec", "assert", "mock", "fixture", "pytest"}, "testing", "test_patterns"),
]


@dataclass
class HuntResult:
    task: str
    hunt_id: str
    queries_used: list[str]
    repos_ingested: list[dict[str, object]]
    hits: list[ScoutHit]


class JulianMetaMorph:
    def __init__(
        self,
        *,
        profile: JulianProfile | None = None,
        github: GitHubClient | None = None,
        quarry: QuarryStore | None = None,
        license_gate: LicenseGate | None = None,
    ) -> None:
        self.profile = profile or JulianProfile()
        self.github = github or GitHubClient()
        self.quarry = quarry or QuarryStore()
        self.license_gate = license_gate or LicenseGate()

    # ── AUTONOMOUS HUNT ───────────────────────────────────────────────────────
    def hunt_task(
        self,
        task: str,
        *,
        repo_limit: int = 5,
        files_per_repo: int = 40,
        hit_limit: int = 10,
    ) -> HuntResult:
        hunt_id = str(uuid.uuid4())[:8]
        queries = self._derive_queries(task)
        seen: dict[str, object] = {}

        for q in queries:
            for repo in self.github.search_repositories(q, limit=10):
                if repo.full_name not in seen:
                    verdict = self.license_gate.classify(repo.license_spdx)
                    if verdict.allowed:
                        seen[repo.full_name] = repo

        candidates = sorted(seen.values(), key=lambda r: r.stars, reverse=True)[:repo_limit]

        ingested_summaries: list[dict[str, object]] = []
        for repo in candidates:
            result = self.ingest_repo(repo.full_name, max_files=files_per_repo)
            ingested_summaries.append(result)

        hits = self.scout_task(task, limit=hit_limit)

        # Store findings into tree DB
        self.quarry.store_hunt_findings(
            hunt_id=hunt_id,
            task=task,
            hits=hits,
            queries=queries,
        )

        return HuntResult(
            task=task,
            hunt_id=hunt_id,
            queries_used=queries,
            repos_ingested=ingested_summaries,
            hits=hits,
        )

    def _derive_queries(self, task: str) -> list[str]:
        tokens = re.findall(r"[A-Za-z][A-Za-z0-9_\-]{2,}", task.lower())
        stop = {
            "with", "from", "into", "that", "this", "have", "will", "your", "about",
            "using", "should", "want", "need", "please", "make", "find", "code",
            "help", "stuff", "things", "something", "anything", "our", "the", "for",
            "and", "can", "you", "get", "all", "some", "use", "its", "also",
        }
        kept = [t for t in tokens if t not in stop]
        if not kept:
            return [task.strip()[:60]]

        queries = [" ".join(kept[:5])]
        if len(kept) >= 2:
            queries.append(" ".join(kept[:2]) + " library")
        if kept:
            queries.append(kept[0] + " implementation")
        return queries

    # ── EXISTING METHODS ──────────────────────────────────────────────────────
    def ingest_repo(self, full_name: str, *, max_files: int = 60) -> dict[str, object]:
        repo = self.github.fetch_repo(full_name)
        verdict = self.license_gate.classify(repo.license_spdx)
        self.quarry.upsert_repo(repo, allowed=verdict.allowed)

        files = self.github.iter_source_files(
            full_name,
            ref=repo.default_branch,
            max_files=max_files,
        )
        ingested = 0
        for repo_file in files:
            enriched = RepoFile(
                path=repo_file.path,
                content=repo_file.content,
                language=repo_file.language,
                sha=repo_file.sha,
                size=repo_file.size,
                symbols=self.extract_symbols(repo_file.path, repo_file.content),
            )
            self.quarry.upsert_file(repo.full_name, enriched)
            ingested += 1
        return {
            "repo": repo.full_name,
            "license": verdict.normalized,
            "allowed": verdict.allowed,
            "ingested_files": ingested,
            "profile": self.profile.name,
        }

    def scout_task(self, task: str, *, limit: int = 8, allowed_only: bool = True) -> list[ScoutHit]:
        query = self.build_query(task)
        hits = self.quarry.search(query, limit=limit, allowed_only=allowed_only)
        return [
            ScoutHit(
                repo_full_name=hit.repo_full_name,
                path=hit.path,
                language=hit.language,
                license_spdx=hit.license_spdx,
                allowed=hit.allowed,
                score=hit.score,
                preview=hit.preview,
                symbols=hit.symbols,
                why=self.explain_hit(task, hit),
            )
            for hit in hits
        ]

    def search_repositories(self, query: str, *, limit: int = 10) -> list[dict[str, object]]:
        results = []
        for repo in self.github.search_repositories(query, limit=limit):
            verdict = self.license_gate.classify(repo.license_spdx)
            results.append(
                {
                    "full_name": repo.full_name,
                    "description": repo.description,
                    "language": repo.language,
                    "stars": repo.stars,
                    "license": verdict.normalized,
                    "allowed": verdict.allowed,
                    "html_url": repo.html_url,
                }
            )
        return results

    @staticmethod
    def build_query(task: str) -> str:
        tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_./:-]{2,}", task.lower())
        stop = {
            "with", "from", "into", "that", "this", "have", "will", "your", "about",
            "using", "should", "want", "need", "please", "make", "find", "code"
        }
        kept: list[str] = []
        for token in tokens:
            if token in stop:
                continue
            if token not in kept:
                kept.append(token)
        if not kept:
            return "code"
        return " ".join(kept[:8])

    @staticmethod
    def classify_hit(hit: ScoutHit) -> tuple[str, str]:
        """Return (category, subcategory) for a hit based on its signals."""
        bag: set[str] = set()
        bag.update(hit.path.lower().replace("/", " ").replace(".", " ").split())
        bag.update(hit.language.lower().split())
        bag.update(s.lower() for s in hit.symbols)
        bag.update(hit.preview.lower().split()[:60])

        for keywords, cat, subcat in _CATEGORY_RULES:
            if keywords & bag:
                return cat, subcat
        return "misc", "general"

    @staticmethod
    def explain_hit(task: str, hit: ScoutHit) -> str:
        """Generate a readable explanation of why this hit is relevant."""
        cat, subcat = JulianMetaMorph.classify_hit(hit)
        sym_list = list(hit.symbols[:5])
        sym_str = ", ".join(f"`{s}`" for s in sym_list) if sym_list else None

        # Category-specific preamble
        preambles = {
            "websocket": "Shows WebSocket implementation patterns",
            "streaming": "Demonstrates async streaming / generator patterns",
            "ai_agent": "Contains LLM / agent tooling patterns",
            "memory": "Implements memory, caching, or storage logic",
            "orchestration": "Provides task scheduling or pipeline patterns",
            "ui_server": "HTTP server or frontend rendering patterns",
            "engine_core": "Julia-specific patterns applicable to the engine core",
            "testing": "Test infrastructure patterns",
            "misc": "General implementation patterns",
        }
        preamble = preambles.get(cat, "Relevant implementation")

        parts = [f"{preamble} ({subcat})"]
        if sym_str:
            parts.append(f"— exposes {sym_str}")
        parts.append(f"— from `{hit.path}` in `{hit.repo_full_name}`")
        parts.append(f"— license: {hit.license_spdx}")
        if task:
            parts.append(f"— matched task: \"{task}\"")
        return " ".join(parts)

    @staticmethod
    def extract_symbols(path: str, content: str) -> tuple[str, ...]:
        suffix = path.rsplit(".", 1)[-1].lower() if "." in path else ""
        patterns = {
            "py": [r"^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)", r"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)"],
            "js": [r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)", r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"],
            "ts": [r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)", r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"],
            "tsx": [r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)", r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"],
            "go": [r"^\s*func\s+([A-Za-z_][A-Za-z0-9_]*)", r"^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\s+struct"],
            "rs": [r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)", r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)"],
            "jl": [r"^\s*function\s+([A-Za-z_][A-Za-z0-9_!]*)", r"^\s*struct\s+([A-Za-z_][A-Za-z0-9_]*)"],
        }
        results: list[str] = []
        for pattern in patterns.get(suffix, []):
            for match in re.finditer(pattern, content, flags=re.MULTILINE):
                name = match.group(1)
                if name not in results:
                    results.append(name)
        return tuple(results[:32])
