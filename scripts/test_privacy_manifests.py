"""Reject misleading privacy declarations, not only malformed plist syntax."""

from copy import deepcopy
from pathlib import Path
import plistlib
import tempfile
import unittest

from scripts import check_privacy_manifests as checker


class PrivacyManifestTests(unittest.TestCase):
    def test_stale_empty_collection_and_wrong_identity_purpose_or_tracking_fail(self):
        with (checker.ROOT / "WalkingPadRemote/PrivacyInfo.xcprivacy").open("rb") as stream:
            source = plistlib.load(stream)
        invalid = []
        empty = deepcopy(source)
        empty["NSPrivacyCollectedDataTypes"] = []
        invalid.append(empty)
        for key, value in [
            ("NSPrivacyCollectedDataTypeLinked", False),
            ("NSPrivacyCollectedDataTypeTracking", True),
            ("NSPrivacyCollectedDataTypePurposes", ["NSPrivacyCollectedDataTypePurposeAnalytics"]),
        ]:
            changed = deepcopy(source)
            changed["NSPrivacyCollectedDataTypes"][0][key] = value
            invalid.append(changed)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "PrivacyInfo.xcprivacy"
            for manifest in invalid:
                with path.open("wb") as stream:
                    plistlib.dump(manifest, stream)
                with self.assertRaises(AssertionError):
                    checker.validate(path, checker.EXPECTED["WalkingPadRemote"], True)
            with path.open("wb") as stream:
                plistlib.dump(source, stream)
            with self.assertRaises(AssertionError):
                checker.validate(path, checker.EXPECTED["WalkingPadRemote"], False)


if __name__ == "__main__":
    unittest.main()
