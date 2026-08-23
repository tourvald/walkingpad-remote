#!/usr/bin/env python3
"""Validate Codex governance ownership, links, and active AGENTS context size."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
ROOT_AGENTS = ROOT / "AGENTS.md"
LIFECYCLE = ROOT / ".agents/skills/walkingpad-pr-lifecycle/SKILL.md"
MINIMAL_CODE = ROOT / ".agents/skills/walkingpad-minimal-code/SKILL.md"
PR_REVIEW = ROOT / ".agents/skills/walkingpad-pr-review/SKILL.md"
PERFORMANCE = ROOT / ".agents/skills/walkingpad-performance/SKILL.md"
ISSUE_TEMPLATE = ROOT / ".github/ISSUE_TEMPLATE/codex-implementation.md"
TELEMETRY_INDEX = ROOT / "docs/telemetry-v2/index.md"

DEFAULT_MAX_INSTRUCTION_BYTES = 32 * 1024
INSTRUCTION_FILENAMES = ("AGENTS.override.md", "AGENTS.md")
EXCLUDED_DIRECTORIES = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "node_modules",
    "venv",
}
FORBIDDEN_HISTORY_HEADINGS = ("## Последние заметки",)

LOCAL_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
NUMERIC_TOKEN_CONTROL = re.compile(
    r"(?:\b\d+[kK]\b[^\n]{0,80}\btoken|\btoken[^\n]{0,80}\b\d+[kK]\b)",
    re.IGNORECASE,
)


def tracked_markdown_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.md"],
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


def discover_instruction_files() -> list[Path]:
    files: list[Path] = []
    for current_root, directory_names, file_names in os.walk(ROOT):
        directory_names[:] = sorted(
            name for name in directory_names if name not in EXCLUDED_DIRECTORIES
        )
        directory = Path(current_root)
        for filename in INSTRUCTION_FILENAMES:
            if filename in file_names:
                files.append(directory / filename)
    return sorted(files)


def active_instruction(directory: Path) -> Path | None:
    for filename in INSTRUCTION_FILENAMES:
        candidate = directory / filename
        if candidate.is_file():
            return candidate
    return None


def instruction_chain(target_directory: Path) -> list[Path]:
    relative = target_directory.resolve().relative_to(ROOT.resolve())
    directories = [ROOT]
    current = ROOT
    for part in relative.parts:
        current /= part
        directories.append(current)
    return [path for directory in directories if (path := active_instruction(directory))]


def instruction_chain_size(chain: list[Path]) -> int:
    return sum(path.stat().st_size for path in chain) + max(0, len(chain) - 1) * 2


def main() -> int:
    errors: list[str] = []

    required_files = (
        ROOT_AGENTS,
        LIFECYCLE,
        MINIMAL_CODE,
        PR_REVIEW,
        PERFORMANCE,
        ISSUE_TEMPLATE,
        TELEMETRY_INDEX,
    )
    for required in required_files:
        if not required.is_file():
            errors.append(f"missing required governance file: {required.relative_to(ROOT)}")

    for policy_file in (ROOT_AGENTS, LIFECYCLE):
        if policy_file.is_file() and NUMERIC_TOKEN_CONTROL.search(
            policy_file.read_text(encoding="utf-8")
        ):
            errors.append(f"numeric token control remains in {policy_file.relative_to(ROOT)}")

    if ISSUE_TEMPLATE.is_file():
        template = ISSUE_TEMPLATE.read_text(encoding="utf-8")
        for duplicated_heading in ("## Global Telemetry V2 invariants", "## Binding execution contract"):
            if duplicated_heading in template:
                errors.append(f"issue template repeats {duplicated_heading!r}")
        for required_heading in ("## Applicable contracts", "## Current binding decisions"):
            if required_heading not in template:
                errors.append(f"issue template is missing {required_heading!r}")

    instruction_files = discover_instruction_files()
    target_directories = {ROOT, *(path.parent for path in instruction_files)}
    largest_chain_bytes = 0
    largest_chain_directory = ROOT
    for path in instruction_files:
        text = path.read_text(encoding="utf-8")
        for heading in FORBIDDEN_HISTORY_HEADINGS:
            if heading in text:
                errors.append(
                    f"forbidden history section in {path.relative_to(ROOT)}: {heading}"
                )
    for directory in sorted(target_directories):
        chain = instruction_chain(directory)
        chain_bytes = instruction_chain_size(chain)
        if chain_bytes > largest_chain_bytes:
            largest_chain_bytes = chain_bytes
            largest_chain_directory = directory
        if chain_bytes > DEFAULT_MAX_INSTRUCTION_BYTES:
            chain_label = " + ".join(str(path.relative_to(ROOT)) for path in chain)
            errors.append(
                f"instruction chain too large at {directory.relative_to(ROOT)}: "
                f"{chain_bytes}/{DEFAULT_MAX_INSTRUCTION_BYTES} bytes ({chain_label})"
            )

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

    directory_label = largest_chain_directory.relative_to(ROOT)
    print(
        "Codex governance OK: "
        f"{len(instruction_files)} AGENTS files, largest active chain "
        f"{largest_chain_bytes}/{DEFAULT_MAX_INSTRUCTION_BYTES} bytes at {directory_label}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
