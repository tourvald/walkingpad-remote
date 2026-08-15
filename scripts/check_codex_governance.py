#!/usr/bin/env python3
"""Validate the repository's Codex governance ownership and local Markdown links."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
ROOT_AGENTS = ROOT / "AGENTS.md"
LIFECYCLE = ROOT / ".agents/skills/walkingpad-pr-lifecycle/SKILL.md"
ISSUE_TEMPLATE = ROOT / ".github/ISSUE_TEMPLATE/codex-implementation.md"
TELEMETRY_INDEX = ROOT / "docs/telemetry-v2/index.md"

LOCAL_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
NUMERIC_TOKEN_CONTROL = re.compile(
    r"(?:\b\d+[kK]\b[^\n]{0,80}\btoken|\btoken[^\n]{0,80}\b\d+[kK]\b)",
    re.IGNORECASE,
)


def tracked_markdown_files() -> list[Path]:
    result = subprocess.run(
        [
            "git",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "--",
            "*.md",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [ROOT / line for line in sorted(result.stdout.splitlines()) if line]


def local_target(raw_target: str) -> str | None:
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        target = target[1 : target.index(">")]
    else:
        target = target.split(maxsplit=1)[0]
    if target.startswith(("http://", "https://", "mailto:", "#")):
        return None
    return unquote(target.split("#", maxsplit=1)[0]) or None


def main() -> int:
    errors: list[str] = []

    for required in (ROOT_AGENTS, LIFECYCLE, ISSUE_TEMPLATE, TELEMETRY_INDEX):
        if not required.is_file():
            errors.append(f"missing required governance file: {required.relative_to(ROOT)}")

    for policy_file in (ROOT_AGENTS, LIFECYCLE):
        if policy_file.is_file() and NUMERIC_TOKEN_CONTROL.search(
            policy_file.read_text(encoding="utf-8")
        ):
            errors.append(
                f"numeric token control remains in {policy_file.relative_to(ROOT)}"
            )

    if ISSUE_TEMPLATE.is_file():
        template = ISSUE_TEMPLATE.read_text(encoding="utf-8")
        for duplicated_heading in (
            "## Global Telemetry V2 invariants",
            "## Binding execution contract",
        ):
            if duplicated_heading in template:
                errors.append(f"issue template repeats {duplicated_heading!r}")
        for required_heading in (
            "## Applicable contracts",
            "## Current binding decisions",
        ):
            if required_heading not in template:
                errors.append(f"issue template is missing {required_heading!r}")

    for markdown_file in tracked_markdown_files():
        text = markdown_file.read_text(encoding="utf-8")
        for match in LOCAL_LINK.finditer(text):
            target = local_target(match.group(1))
            if target is None:
                continue
            resolved = (markdown_file.parent / target).resolve()
            if not resolved.exists():
                errors.append(
                    f"broken local link in {markdown_file.relative_to(ROOT)}: {target}"
                )

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    print("Codex governance ownership and local Markdown links: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
