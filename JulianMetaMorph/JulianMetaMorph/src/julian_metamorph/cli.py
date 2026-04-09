from __future__ import annotations

import argparse
import dataclasses
import json
from pathlib import Path

import uvicorn

from .forge import SkillForge
from .profile import JulianProfile
from .quarry import QuarryStore
from .scout import JulianMetaMorph
from .service import create_app
from .splash_garden import SplashBenchConfig, SplashGardenConfig, render_splash_garden, run_splash_garden_bench


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="julian-metamorph")
    parser.add_argument("--db", default="data/quarry.db", help="Path to the SQLite quarry database.")
    sub = parser.add_subparsers(dest="command", required=True)

    prompt_cmd = sub.add_parser("julian-prompt", help="Render Julian's operating prompt.")
    prompt_cmd.add_argument("--task", default="", help="Optional task seed.")

    search_repo_cmd = sub.add_parser("search-repos", help="Search GitHub repositories live.")
    search_repo_cmd.add_argument("query")
    search_repo_cmd.add_argument("--limit", type=int, default=10)

    ingest_cmd = sub.add_parser("ingest-repo", help="Ingest a GitHub repo into the local quarry.")
    ingest_cmd.add_argument("repo")
    ingest_cmd.add_argument("--max-files", type=int, default=60)

    scout_cmd = sub.add_parser("scout-task", help="Scout the local quarry for task-relevant fragments.")
    scout_cmd.add_argument("task")
    scout_cmd.add_argument("--limit", type=int, default=8)
    scout_cmd.add_argument("--include-blocked", action="store_true")

    forge_cmd = sub.add_parser("forge-skill", help="Forge a reusable skill module from scout hits.")
    forge_cmd.add_argument("name")
    forge_cmd.add_argument("task")
    forge_cmd.add_argument("--limit", type=int, default=8)
    forge_cmd.add_argument("--out", default="skills")

    splash_cmd = sub.add_parser(
        "splash-garden",
        help="Render a prototype RGB+D ripple image using the Splash Garden field engine.",
    )
    splash_cmd.add_argument("prompt", help="Seed prompt for the ripple field.")
    splash_cmd.add_argument("--width", type=int, default=96)
    splash_cmd.add_argument("--height", type=int, default=96)
    splash_cmd.add_argument("--steps", type=int, default=72)
    splash_cmd.add_argument("--out", default="data/splash_garden.png")
    splash_cmd.add_argument("--delay-out", default="data/splash_garden_delay.png")
    splash_cmd.add_argument("--meta-out", default="data/splash_garden.json")
    splash_cmd.add_argument("--energy", type=float, default=1.0)
    splash_cmd.add_argument("--delay-gain", type=float, default=1.0)
    splash_cmd.add_argument("--structure-gain", type=float, default=1.0)
    splash_cmd.add_argument("--spectral-tilt", type=float, default=0.0)
    splash_cmd.add_argument("--ring-scale", type=float, default=1.0)

    bench_cmd = sub.add_parser(
        "splash-garden-bench",
        help="Run a multi-case Splash Garden bench to probe delay, structure, and spectral behavior.",
    )
    bench_cmd.add_argument("prompt", help="Seed prompt for the bench suite.")
    bench_cmd.add_argument("--width", type=int, default=96)
    bench_cmd.add_argument("--height", type=int, default=96)
    bench_cmd.add_argument("--steps", type=int, default=72)
    bench_cmd.add_argument("--out-dir", default="data/splash_garden_bench")

    serve_cmd = sub.add_parser("serve", help="Run the standalone Julian MetaMorph API service.")
    serve_cmd.add_argument("--host", default="127.0.0.1")
    serve_cmd.add_argument("--port", type=int, default=8765)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    profile = JulianProfile()
    quarry = QuarryStore(args.db)
    app = JulianMetaMorph(profile=profile, quarry=quarry)

    if args.command == "julian-prompt":
        print(profile.render_prompt(args.task or None))
        return 0

    if args.command == "search-repos":
        print(json.dumps(app.search_repositories(args.query, limit=args.limit), indent=2))
        return 0

    if args.command == "ingest-repo":
        print(json.dumps(app.ingest_repo(args.repo, max_files=args.max_files), indent=2))
        return 0

    if args.command == "scout-task":
        hits = app.scout_task(args.task, limit=args.limit, allowed_only=not args.include_blocked)
        print(json.dumps([dataclasses.asdict(hit) for hit in hits], indent=2))
        return 0

    if args.command == "forge-skill":
        hits = app.scout_task(args.task, limit=args.limit)
        forged = SkillForge(profile=profile).forge(args.name, args.task, hits, out_dir=Path(args.out))
        print(
            json.dumps(
                {
                    "name": forged.name,
                    "task": forged.task,
                    "module_path": str(forged.module_path),
                    "manifest_path": str(forged.manifest_path),
                },
                indent=2,
            )
        )
        return 0

    if args.command == "splash-garden":
        result = render_splash_garden(
            SplashGardenConfig(
                prompt=args.prompt,
                width=args.width,
                height=args.height,
                steps=args.steps,
                out_path=args.out,
                delay_out_path=args.delay_out,
                meta_out_path=args.meta_out,
                energy=args.energy,
                delay_gain=args.delay_gain,
                structure_gain=args.structure_gain,
                spectral_tilt=args.spectral_tilt,
                ring_scale=args.ring_scale,
            )
        )
        print(json.dumps(result, indent=2))
        return 0

    if args.command == "splash-garden-bench":
        result = run_splash_garden_bench(
            SplashBenchConfig(
                prompt=args.prompt,
                width=args.width,
                height=args.height,
                steps=args.steps,
                out_dir=args.out_dir,
            )
        )
        print(json.dumps(result, indent=2))
        return 0

    if args.command == "serve":
        uvicorn.run(create_app(db_path=args.db), host=args.host, port=args.port)
        return 0

    parser.error(f"Unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
