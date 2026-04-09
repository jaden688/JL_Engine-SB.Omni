from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from uuid import uuid4

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .forge import SkillForge
from .profile import JulianProfile
from .quarry import QuarryStore
from .scout import JulianMetaMorph
from .splash_garden import SplashBenchConfig, SplashGardenConfig, render_splash_garden, run_splash_garden_bench


class SearchReposRequest(BaseModel):
    query: str
    limit: int = 10


class IngestRepoRequest(BaseModel):
    repo: str
    max_files: int = 60


class ScoutTaskRequest(BaseModel):
    task: str
    limit: int = 8
    include_blocked: bool = False


class HuntRequest(BaseModel):
    task: str
    repo_limit: int = 5
    files_per_repo: int = 40
    hit_limit: int = 10


class PushFindingsRequest(BaseModel):
    repo_name: str = "sparkbyte-engine-findings"
    hunt_id: str | None = None


class ForgeSkillRequest(BaseModel):
    name: str
    task: str
    limit: int = 8
    out_dir: str = "skills"


class JulianPromptRequest(BaseModel):
    task: str = ""


class SplashLiveRequest(BaseModel):
    prompt: str = "unseen vision"
    width: int = Field(default=96, ge=24, le=192)
    height: int = Field(default=96, ge=24, le=192)
    steps: int = Field(default=72, ge=8, le=200)
    energy: float = Field(default=1.0, ge=0.35, le=2.4)
    delay_gain: float = Field(default=1.0, ge=0.35, le=2.6)
    structure_gain: float = Field(default=1.0, ge=0.45, le=2.6)
    spectral_tilt: float = Field(default=0.0, ge=-1.0, le=1.0)
    ring_scale: float = Field(default=1.0, ge=0.6, le=1.45)
    guide_label: str | None = None
    guide_luma: list[list[float]] | None = None
    guide_edges: list[list[float]] | None = None


class SplashBenchRequest(BaseModel):
    prompt: str = "unseen vision"
    width: int = Field(default=96, ge=24, le=192)
    height: int = Field(default=96, ge=24, le=192)
    steps: int = Field(default=72, ge=8, le=200)
    guide_label: str | None = None
    guide_luma: list[list[float]] | None = None
    guide_edges: list[list[float]] | None = None


def _artifact_url(path: str | Path, *, data_root: Path) -> str:
    resolved = Path(path).resolve()
    relative = resolved.relative_to(data_root.resolve())
    return f"/artifacts/{relative.as_posix()}"


def create_app(
    *, db_path: str | Path = "data/quarry.db", data_root: str | Path | None = None
) -> FastAPI:
    profile = JulianProfile()
    quarry = QuarryStore(db_path)
    morph = JulianMetaMorph(profile=profile, quarry=quarry)
    forge = SkillForge(profile=profile)
    data_dir = Path(data_root) if data_root is not None else Path(db_path).resolve().parent

    app = FastAPI(title="Julian MetaMorph Service")

    # Serve the launcher UI
    _static = Path(__file__).parent.parent.parent / "static"
    if _static.exists():
        app.mount("/static", StaticFiles(directory=str(_static)), name="static")
    data_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/artifacts", StaticFiles(directory=str(data_dir)), name="artifacts")

    @app.get("/", include_in_schema=False)
    def root() -> FileResponse:
        return FileResponse(str(_static / "launcher.html"))

    @app.get("/ripple-scope", include_in_schema=False)
    def ripple_scope() -> FileResponse:
        return FileResponse(str(_static / "ripple_scope.html"))

    @app.post("/hunt")
    def hunt(request: HuntRequest) -> dict[str, object]:
        result = morph.hunt_task(
            request.task,
            repo_limit=request.repo_limit,
            files_per_repo=request.files_per_repo,
            hit_limit=request.hit_limit,
        )
        return {
            "task": result.task,
            "hunt_id": result.hunt_id,
            "queries_used": result.queries_used,
            "repos_ingested": result.repos_ingested,
            "hits": [asdict(h) for h in result.hits],
        }

    @app.get("/findings/tree")
    def findings_tree(hunt_id: str | None = None) -> dict[str, object]:
        nodes = quarry.get_findings_tree(hunt_id=hunt_id)
        return {"nodes": nodes, "count": len(nodes)}

    @app.get("/findings/hunts")
    def findings_hunts() -> dict[str, object]:
        return {"hunts": quarry.list_hunts()}

    @app.post("/findings/push")
    def push_findings(request: PushFindingsRequest) -> dict[str, object]:
        nodes = quarry.get_findings_tree(hunt_id=request.hunt_id)
        if not nodes:
            return {"error": "No findings to push", "url": None}
        url = morph.github.push_findings_to_github(
            nodes, repo_name=request.repo_name
        )
        return {"url": url, "pushed": sum(1 for n in nodes if n["node_type"] == "finding")}

    @app.get("/health")
    def health() -> dict[str, object]:
        return {
            "status": "ok",
            "service": "julian-metamorph",
            "profile": profile.name,
            "quarry": quarry.summary(),
        }

    @app.post("/julian/prompt")
    def julian_prompt(request: JulianPromptRequest) -> dict[str, str]:
        return {"profile": profile.name, "prompt": profile.render_prompt(request.task or None)}

    @app.post("/repos/search")
    def search_repos(request: SearchReposRequest) -> dict[str, object]:
        return {"results": morph.search_repositories(request.query, limit=request.limit)}

    @app.post("/repos/ingest")
    def ingest_repo(request: IngestRepoRequest) -> dict[str, object]:
        return morph.ingest_repo(request.repo, max_files=request.max_files)

    @app.post("/tasks/scout")
    def scout_task(request: ScoutTaskRequest) -> dict[str, object]:
        hits = morph.scout_task(
            request.task,
            limit=request.limit,
            allowed_only=not request.include_blocked,
        )
        return {"hits": [asdict(hit) for hit in hits]}

    @app.post("/skills/forge")
    def forge_skill(request: ForgeSkillRequest) -> dict[str, object]:
        hits = morph.scout_task(request.task, limit=request.limit, allowed_only=True)
        forged = forge.forge(request.name, request.task, hits, out_dir=request.out_dir)
        return {
            "name": forged.name,
            "task": forged.task,
            "module_path": str(forged.module_path),
            "manifest_path": str(forged.manifest_path),
        }

    @app.post("/splash/live")
    def splash_live(request: SplashLiveRequest) -> dict[str, object]:
        run_id = uuid4().hex[:12]
        run_dir = data_dir / "live" / "splash" / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        result = render_splash_garden(
            SplashGardenConfig(
                prompt=request.prompt,
                width=request.width,
                height=request.height,
                steps=request.steps,
                out_path=str(run_dir / "rgb.png"),
                delay_out_path=str(run_dir / "delay.png"),
                meta_out_path=str(run_dir / "meta.json"),
                energy=request.energy,
                delay_gain=request.delay_gain,
                structure_gain=request.structure_gain,
                spectral_tilt=request.spectral_tilt,
                ring_scale=request.ring_scale,
                guide_label=request.guide_label,
                guide_luma=request.guide_luma,
                guide_edges=request.guide_edges,
            )
        )
        artifact_urls = {
            key: _artifact_url(path, data_root=data_dir)
            for key, path in result["output_files"].items()
        }
        artifact_urls["meta"] = _artifact_url(result["meta_path"], data_root=data_dir)
        return {
            "status": "ok",
            "run_id": run_id,
            "artifact_urls": artifact_urls,
            "result": result,
        }

    @app.post("/splash/live/bench")
    def splash_live_bench(request: SplashBenchRequest) -> dict[str, object]:
        run_id = uuid4().hex[:12]
        out_dir = data_dir / "live" / "bench" / run_id
        out_dir.mkdir(parents=True, exist_ok=True)
        manifest = run_splash_garden_bench(
            SplashBenchConfig(
                prompt=request.prompt,
                width=request.width,
                height=request.height,
                steps=request.steps,
                out_dir=str(out_dir),
                guide_label=request.guide_label,
                guide_luma=request.guide_luma,
                guide_edges=request.guide_edges,
            )
        )
        for case in manifest["cases"]:
            case["artifact_urls"] = {
                key: _artifact_url(path, data_root=data_dir)
                for key, path in case["files"].items()
            }
            case["meta_url"] = _artifact_url(case["meta_path"], data_root=data_dir)
        manifest["manifest_url"] = _artifact_url(manifest["manifest_path"], data_root=data_dir)
        manifest["report_url"] = _artifact_url(manifest["report_path"], data_root=data_dir)
        return {
            "status": "ok",
            "run_id": run_id,
            "manifest": manifest,
        }

    return app


app = create_app()
