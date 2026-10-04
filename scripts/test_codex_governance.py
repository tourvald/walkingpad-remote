#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import check_codex_governance as governance


class GoalGovernanceTests(unittest.TestCase):
    def check(self, owner: str, content: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory(dir=governance.ROOT) as directory:
            path = Path(directory) / "policy.txt"
            path.write_text(content, encoding="utf-8")
            output = io.StringIO()
            with patch.object(governance, owner, path), contextlib.redirect_stdout(output):
                result = governance.main()
            return result, output.getvalue()

    def test_current_canonical_sections_pass(self) -> None:
        for owner in ("WORKFLOW", "ISSUE_TEMPLATE"):
            with self.subTest(owner=owner):
                result, output = self.check(owner, getattr(governance, owner).read_text())
                self.assertEqual(result, 0, output)

    def test_missing_goal_section_fails_closed(self) -> None:
        for owner, marker in (
            ("WORKFLOW", "## Decision authority and autonomy modes"),
            ("WORKFLOW", "### Goal eligibility"),
            ("WORKFLOW", "## Nightly Goal Batch"),
            ("WORKFLOW", "## Morning PM Pass"),
            ("ISSUE_TEMPLATE", "## Goal eligibility"),
        ):
            with self.subTest(owner=owner, marker=marker):
                content = getattr(governance, owner).read_text().replace(marker, "")
                result, output = self.check(owner, content)
                self.assertEqual(result, 1)
                self.assertIn("missing Goal contract section in", output)
                self.assertIn(marker, output)

    def test_policy_prose_is_not_a_string_assertion(self) -> None:
        content = governance.WORKFLOW.read_text().replace(
            "Classification never activates a Goal or grants merge authority.",
            "Eligibility metadata alone grants no execution authority.",
        )
        result, output = self.check("WORKFLOW", content)
        self.assertEqual(result, 0, output)


if __name__ == "__main__":
    unittest.main()
