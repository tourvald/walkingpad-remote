#!/usr/bin/env python3
"""Report exact base-to-head growth and conservative anti-bloat review prompts."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATEGORIES = ("production", "tests", "docs_governance", "tooling_config")
CONFIG_BASENAMES = {
    "Package.swift", "Package.resolved", "Podfile", "Podfile.lock",
    "Cartfile", "Cartfile.resolved", "pyproject.toml", "requirements.txt",
}
DEPENDENCY_BASENAMES = set(CONFIG_BASENAMES)
CONFIG_PATHS = {".codex/config.toml"}
CANDIDATE_PATTERNS = {
    "durable-state": re.compile(
        r"^\s*(?:@(?:State|StateObject|Published)\b.*|"
        r"(?:private|fileprivate|internal|public)?\s*var\s+\w+.*"
        r"(?:\[[^]]+:[^]]+\]|\bTimer\??\b|\bTask<|\bTask\??\b))"
    ),
    "timer-polling": re.compile(
        r"\b(?:Timer\s*\(|scheduledTimer\b|asyncAfter\b|"
        r"Task\.sleep\b|sleep\s*\(|\.timer\s*\()"
    ),
    "abstraction": re.compile(
        r"^\s*(?:(?:final\s+)?(?:class|struct|actor)\s+"
        r"\w*(?:Coordinator|Manager|Factory)\b|"
        r"(?:public\s+|private\s+|internal\s+|fileprivate\s+)?"
        r"protocol\s+\w+)"
    ),
}


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout


def classify_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    name = Path(normalized).name
    if (
        "/Tests/" in normalized
        or "/tests/" in normalized
        or normalized.startswith(("Tests/", "tests/"))
        or name.startswith("test_")
    ):
        return "tests"
    if (
        normalized.endswith(".md")
        or name in {"AGENTS.md", "AGENTS.override.md"}
        or normalized.startswith(("docs/", ".agents/", ".github/ISSUE_TEMPLATE/"))
    ):
        return "docs_governance"
    if (
        normalized.startswith(("scripts/", "tools/", ".github/workflows/"))
        or name in CONFIG_BASENAMES
        or normalized in CONFIG_PATHS
        or normalized.endswith(".xcodeproj/project.pbxproj")
    ):
        return "tooling_config"
    return "production"


def build_report(
    base: str,
    head: str,
    *,
    cwd: Path = ROOT,
    narrow_bugfix: bool = False,
) -> dict[str, object]:
    stats = {category: {"added": 0, "removed": 0} for category in CATEGORIES}
    paths = {category: [] for category in CATEGORIES}
    changed_paths: list[str] = []

    numstat = git(
        "diff", "--find-renames", "--numstat", f"{base}...{head}", "--", cwd=cwd
    )
    for row in numstat.splitlines():
        added, removed, path = row.split("\t", maxsplit=2)
        category = classify_path(path)
        paths[category].append(path)
        changed_paths.append(path)
        stats[category]["added"] += 0 if added == "-" else int(added)
        stats[category]["removed"] += 0 if removed == "-" else int(removed)

    for values in stats.values():
        values["net"] = values["added"] - values["removed"]
        values["churn"] = values["added"] + values["removed"]

    added_files = git(
        "diff", "--find-renames", "--name-only", "--diff-filter=A",
        f"{base}...{head}", "--", cwd=cwd
    ).splitlines()
    new_production_files = sorted(
        path for path in added_files if path and classify_path(path) == "production"
    )

    config_paths = sorted(
        path for path in changed_paths
        if classify_path(path) == "tooling_config"
        or Path(path).name in CONFIG_BASENAMES
        or path in CONFIG_PATHS
        or path.endswith(".xcodeproj/project.pbxproj")
    )
    dependency_paths = sorted(
        path for path in changed_paths if Path(path).name in DEPENDENCY_BASENAMES
    )

    candidates: list[dict[str, str]] = []
    current_path: str | None = None
    diff = git("diff", "--find-renames", "-U0", f"{base}...{head}", "--", cwd=cwd)
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
            continue
        if (
            current_path is None
            or classify_path(current_path) != "production"
            or not line.startswith("+")
            or line.startswith("+++")
        ):
            continue
        added_line = line[1:]
        for kind, pattern in CANDIDATE_PATTERNS.items():
            if pattern.search(added_line):
                candidates.append(
                    {"kind": kind, "path": current_path, "snippet": added_line.strip()[:240]}
                )

    hard_stops: list[str] = []
    if narrow_bugfix and len(paths["production"]) > 5:
        hard_stops.append("narrow-bugfix-production-files>5")
    if narrow_bugfix and stats["production"]["churn"] > 500:
        hard_stops.append("narrow-bugfix-production-churn>500")

    prompts: list[str] = []
    if config_paths:
        prompts.append("tooling-or-configuration-surface-changed")
    if dependency_paths:
        prompts.append("dependency-manifest-or-lockfile-changed")
    prompts.extend(
        f"added-{kind}-candidate" for kind in sorted({item["kind"] for item in candidates})
    )

    return {
        "base": base,
        "head": head,
        "production_files_changed": sorted(paths["production"]),
        "production": stats["production"],
        "tests": stats["tests"],
        "docs_governance": stats["docs_governance"],
        "tooling_config": stats["tooling_config"],
        "new_production_files": new_production_files,
        "config_paths_changed": config_paths,
        "dependency_paths_changed": dependency_paths,
        "added_surface_candidates": candidates,
        "review_prompts": prompts,
        "hard_stop_candidates": hard_stops,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("head")
    parser.add_argument("--narrow-bugfix", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--fail-on-tripwire", action="store_true")
    args = parser.parse_args()

    report = build_report(args.base, args.head, narrow_bugfix=args.narrow_bugfix)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        production = report["production"]
        print(f"Code growth: {args.base}...{args.head}")
        print(
            f"Production: {len(report['production_files_changed'])} files, "
            f"+{production['added']}/-{production['removed']} "
            f"(net {production['net']}, churn {production['churn']})"
        )
        print(f"New production files: {len(report['new_production_files'])}")
        for category in ("tests", "docs_governance", "tooling_config"):
            values = report[category]
            print(
                f"{category}: +{values['added']}/-{values['removed']} "
                f"(net {values['net']})"
            )
        if report["review_prompts"]:
            print("Review prompts: " + ", ".join(report["review_prompts"]))
        if report["hard_stop_candidates"]:
            print("Hard-stop candidates: " + ", ".join(report["hard_stop_candidates"]))

    return 2 if args.fail_on_tripwire and report["hard_stop_candidates"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
