#!/usr/bin/env python3
"""Report exact base-to-head code growth and conservative anti-bloat review prompts."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

TEST_PATH_PARTS = ("/Tests/", "/tests/", "Tests/", "tests/")
DOC_GOV_PREFIXES = ("docs/", ".agents/", ".github/ISSUE_TEMPLATE/")
TOOLING_PREFIXES = ("scripts/", "tools/", ".github/workflows/")
CONFIG_BASENAMES = {
    "Package.swift",
    "Package.resolved",
    "Podfile",
    "Podfile.lock",
    "Cartfile",
    "Cartfile.resolved",
    "pyproject.toml",
    "requirements.txt",
}
CONFIG_PATHS = {".codex/config.toml"}
DEPENDENCY_NAMES = {
    "Package.swift",
    "Package.resolved",
    "Podfile",
    "Podfile.lock",
    "Cartfile",
    "Cartfile.resolved",
    "pyproject.toml",
    "requirements.txt",
}

CANDIDATE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "durable-state",
        re.compile(
            r"^\s*(?:@(?:State|StateObject|Published)\b.*|"
            r"(?:private|fileprivate|internal|public)?\s*var\s+\w+.*"
            r"(?:\[[^]]+:[^]]+\]|\bTimer\??\b|\bTask<|\bTask\??\b))"
        ),
    ),
    (
        "timer-polling",
        re.compile(
            r"\b(?:Timer\s*\(|scheduledTimer\b|asyncAfter\b|Task\.sleep\b|"
            r"sleep\s*\(|\.timer\s*\()"
        ),
    ),
    (
        "abstraction",
        re.compile(
            r"^\s*(?:(?:final\s+)?(?:class|struct|actor)\s+\w*(?:Coordinator|Manager|Factory)\b|"
            r"(?:public\s+|private\s+|internal\s+|fileprivate\s+)?protocol\s+\w+)"
        ),
    ),
)


@dataclass(frozen=True)
class LineStats:
    added: int = 0
    removed: int = 0

    @property
    def net(self) -> int:
        return self.added - self.removed

    @property
    def churn(self) -> int:
        return self.added + self.removed


def _git(*args: str, cwd: Path = ROOT) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def classify_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    name = Path(normalized).name
    if any(part in normalized for part in TEST_PATH_PARTS) or name.startswith("test_"):
        return "tests"
    if (
        normalized.endswith(".md")
        or name in {"AGENTS.md", "AGENTS.override.md"}
        or normalized.startswith(DOC_GOV_PREFIXES)
    ):
        return "docs_governance"
    if (
        normalized.startswith(TOOLING_PREFIXES)
        or name in CONFIG_BASENAMES
        or normalized in CONFIG_PATHS
        or normalized.endswith(".xcodeproj/project.pbxproj")
    ):
        return "tooling_config"
    return "production"



def _numstat(base: str, head: str, cwd: Path) -> dict[str, LineStats]:
    rows: dict[str, LineStats] = {}
    output = _git(
        "diff",
        "--find-renames",
        "--numstat",
        f"{base}...{head}",
        "--",
        cwd=cwd,
    )
    for raw in output.splitlines():
        added, removed, path = raw.split("\t", maxsplit=2)
        rows[path] = LineStats(
            added=0 if added == "-" else int(added),
            removed=0 if removed == "-" else int(removed),
        )
    return rows


def _new_files(base: str, head: str, cwd: Path) -> list[str]:
    output = _git(
        "diff",
        "--find-renames",
        "--name-only",
        "--diff-filter=A",
        f"{base}...{head}",
        "--",
        cwd=cwd,
    )
    return [line for line in output.splitlines() if line]


def _added_production_lines(base: str, head: str, cwd: Path) -> list[tuple[str, str]]:
    output = _git("diff", "--find-renames", "-U0", f"{base}...{head}", "--", cwd=cwd)
    current_path: str | None = None
    result: list[tuple[str, str]] = []
    for line in output.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
            continue
        if current_path is None or classify_path(current_path) != "production":
            continue
        if line.startswith("+") and not line.startswith("+++"):
            result.append((current_path, line[1:]))
    return result


def build_report(
    base: str,
    head: str,
    *,
    cwd: Path = ROOT,
    narrow_bugfix: bool = False,
) -> dict[str, object]:
    per_path = _numstat(base, head, cwd)
    by_category: dict[str, LineStats] = {}
    paths_by_category: dict[str, list[str]] = {}
    for path, stats in per_path.items():
        category = classify_path(path)
        paths_by_category.setdefault(category, []).append(path)
        current = by_category.get(category, LineStats())
        by_category[category] = LineStats(
            current.added + stats.added,
            current.removed + stats.removed,
        )

    new_production_files = sorted(
        path for path in _new_files(base, head, cwd) if classify_path(path) == "production"
    )
    changed_paths = sorted(per_path)
    config_paths = sorted(
        path
        for path in changed_paths
        if classify_path(path) == "tooling_config"
        or Path(path).name in CONFIG_BASENAMES
        or path in CONFIG_PATHS
        or path.endswith(".xcodeproj/project.pbxproj")
    )
    dependency_paths = sorted(
        path for path in changed_paths if Path(path).name in DEPENDENCY_NAMES
    )

    candidates: list[dict[str, str]] = []
    for path, line in _added_production_lines(base, head, cwd):
        for kind, pattern in CANDIDATE_PATTERNS:
            if pattern.search(line):
                candidates.append(
                    {"kind": kind, "path": path, "snippet": line.strip()[:240]}
                )

    production = by_category.get("production", LineStats())
    hard_stop_candidates: list[str] = []
    if narrow_bugfix and len(paths_by_category.get("production", [])) > 5:
        hard_stop_candidates.append("narrow-bugfix-production-files>5")
    if narrow_bugfix and production.churn > 500:
        hard_stop_candidates.append("narrow-bugfix-production-churn>500")

    review_prompts: list[str] = []
    if config_paths:
        review_prompts.append("tooling-or-configuration-surface-changed")
    if dependency_paths:
        review_prompts.append("dependency-manifest-or-lockfile-changed")
    for kind in sorted({candidate["kind"] for candidate in candidates}):
        review_prompts.append(f"added-{kind}-candidate")

    return {
        "base": base,
        "head": head,
        "production_files_changed": sorted(paths_by_category.get("production", [])),
        "production": asdict(production)
        | {"net": production.net, "churn": production.churn},
        "tests": asdict(by_category.get("tests", LineStats()))
        | {
            "net": by_category.get("tests", LineStats()).net,
            "churn": by_category.get("tests", LineStats()).churn,
        },
        "docs_governance": asdict(by_category.get("docs_governance", LineStats()))
        | {
            "net": by_category.get("docs_governance", LineStats()).net,
            "churn": by_category.get("docs_governance", LineStats()).churn,
        },
        "tooling_config": asdict(by_category.get("tooling_config", LineStats()))
        | {
            "net": by_category.get("tooling_config", LineStats()).net,
            "churn": by_category.get("tooling_config", LineStats()).churn,
        },
        "new_production_files": new_production_files,
        "config_paths_changed": config_paths,
        "dependency_paths_changed": dependency_paths,
        "added_surface_candidates": candidates,
        "review_prompts": review_prompts,
        "hard_stop_candidates": hard_stop_candidates,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", help="Exact accepted base commit/ref")
    parser.add_argument("head", help="Exact reviewed head commit/ref")
    parser.add_argument(
        "--narrow-bugfix",
        action="store_true",
        help="Enable the >5 production files / >500 production LOC churn tripwires.",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    parser.add_argument(
        "--fail-on-tripwire",
        action="store_true",
        help="Exit 2 when a script-detectable hard-stop candidate is present.",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    report = build_report(args.base, args.head, narrow_bugfix=args.narrow_bugfix)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        production = report["production"]
        print(f"Code growth: {args.base}...{args.head}")
        print(
            "Production: "
            f"{len(report['production_files_changed'])} files, "
            f"+{production['added']}/-{production['removed']} "
            f"(net {production['net']}, churn {production['churn']})"
        )
        print(f"New production files: {len(report['new_production_files'])}")
        for category in ("tests", "docs_governance", "tooling_config"):
            stats = report[category]
            print(
                f"{category}: +{stats['added']}/-{stats['removed']} "
                f"(net {stats['net']})"
            )
        if report["review_prompts"]:
            print("Review prompts: " + ", ".join(report["review_prompts"]))
        if report["hard_stop_candidates"]:
            print("Hard-stop candidates: " + ", ".join(report["hard_stop_candidates"]))
    return 2 if args.fail_on_tripwire and report["hard_stop_candidates"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
