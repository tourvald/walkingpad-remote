#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from code_growth_report import build_report


class CodeGrowthReportTests(unittest.TestCase):
    def git(self, cwd: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def commit(self, cwd: Path, message: str) -> str:
        self.git(cwd, "add", ".")
        self.git(cwd, "commit", "-m", message)
        return self.git(cwd, "rev-parse", "HEAD")

    def make_repo(self) -> Path:
        root = Path(tempfile.mkdtemp(prefix="code-growth-test-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(root)], check=False))
        self.git(root, "init")
        self.git(root, "config", "user.email", "test@example.com")
        self.git(root, "config", "user.name", "Test")
        return root

    def write(self, root: Path, path: str, content: str) -> None:
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def test_classifies_growth_and_surfaces_conservative_review_candidates(self) -> None:
        root = self.make_repo()
        self.write(root, "ios/App/Sources/App.swift", "struct App {}\n")
        self.write(root, "ios/App/Tests/AppTests.swift", "func testBase() {}\n")
        self.write(root, "docs/readme.md", "# Base\n")
        self.write(root, "Package.swift", "// package\n")
        base = self.commit(root, "base")

        self.write(
            root,
            "ios/App/Sources/FooCoordinator.swift",
            """final class FooCoordinator {
    private var cache: [String: Int] = [:]
    private var timer: Timer?
    func poll() { _ = Timer(timeInterval: 1, repeats: true) { _ in } }
}
""",
        )
        self.write(
            root,
            "ios/App/Sources/App.swift",
            "struct App {}\nfunc addedBehavior() {}\n",
        )
        self.write(
            root,
            "ios/App/Tests/AppTests.swift",
            "func testBase() {}\n" + "".join(f"// test {i}\n" for i in range(600)),
        )
        self.write(root, "docs/readme.md", "# Base\nMore governance text\n")
        self.write(
            root,
            "Package.swift",
            "// package\n// dependency manifest changed\n",
        )
        head = self.commit(root, "head")

        report = build_report(base, head, cwd=root, narrow_bugfix=True)

        self.assertEqual(
            report["production_files_changed"],
            ["ios/App/Sources/App.swift", "ios/App/Sources/FooCoordinator.swift"],
        )
        self.assertEqual(report["new_production_files"], ["ios/App/Sources/FooCoordinator.swift"])
        self.assertGreater(report["tests"]["added"], 500)
        self.assertGreater(report["docs_governance"]["added"], 0)
        self.assertIn("Package.swift", report["config_paths_changed"])
        self.assertIn("Package.swift", report["dependency_paths_changed"])
        kinds = {candidate["kind"] for candidate in report["added_surface_candidates"]}
        self.assertEqual(kinds, {"abstraction", "durable-state", "timer-polling"})
        self.assertEqual(report["hard_stop_candidates"], [])
        self.assertIn("added-durable-state-candidate", report["review_prompts"])
        self.assertIn("dependency-manifest-or-lockfile-changed", report["review_prompts"])

    def test_narrow_bugfix_tripwire_ignores_large_tests_but_flags_broad_production(self) -> None:
        root = self.make_repo()
        self.write(root, "tests/test_big.py", "# base\n")
        base = self.commit(root, "base")

        self.write(
            root,
            "tests/test_big.py",
            "# base\n" + "".join(f"# coverage {i}\n" for i in range(1000)),
        )
        for index in range(6):
            self.write(root, f"Sources/F{index}.swift", f"struct F{index} {{}}\n")
        head = self.commit(root, "head")

        report = build_report(base, head, cwd=root, narrow_bugfix=True)

        self.assertEqual(len(report["production_files_changed"]), 6)
        self.assertIn(
            "narrow-bugfix-production-files>5",
            report["hard_stop_candidates"],
        )
        self.assertNotIn(
            "narrow-bugfix-production-churn>500",
            report["hard_stop_candidates"],
        )
        self.assertGreater(report["tests"]["added"], 900)


if __name__ == "__main__":
    unittest.main()
