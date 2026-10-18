#!/usr/bin/env python3
"""Validate the audited source declarations and optional Release bundle copies."""
import argparse
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "ios/WalkingPadRemote/WalkingPadRemote"
EXPECTED = {
    "WalkingPadRemote": {
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
    },
    "WalkingPadRemoteWatch Watch App": {},
    "WorkoutLiveActivity": {},
}
SUPPORT_TYPES = [
    "Health", "Fitness", "Name", "EmailAddress", "UserID",
    "CustomerSupport", "OtherDiagnosticData",
]


def validate(path, expected, support_collection=False):
    with path.open("rb") as stream:
        manifest = plistlib.load(stream)
    assert manifest == {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [
            {
                "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataType" + kind,
                "NSPrivacyCollectedDataTypeLinked": True,
                "NSPrivacyCollectedDataTypeTracking": False,
                "NSPrivacyCollectedDataTypePurposes": [
                    "NSPrivacyCollectedDataTypePurposeAppFunctionality"
                ],
            }
            for kind in SUPPORT_TYPES
        ] if support_collection else [],
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": api, "NSPrivacyAccessedAPITypeReasons": reasons}
            for api, reasons in expected.items()
        ],
    }, f"Unexpected privacy declaration: {path}"
    print(f"PASS: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Built Release iOS .app")
    args = parser.parse_args()
    for target, expected in EXPECTED.items():
        validate(ROOT / target / "PrivacyInfo.xcprivacy", expected, target == "WalkingPadRemote")
    if args.app:
        bundles = {
            "WalkingPadRemote": args.app,
            "WalkingPadRemoteWatch Watch App": args.app / "Watch/WalkingPadRemoteWatch Watch App.app",
            "WorkoutLiveActivity": args.app / "PlugIns/WorkoutLiveActivity.appex",
        }
        for target, bundle in bundles.items():
            validate(bundle / "PrivacyInfo.xcprivacy", EXPECTED[target], target == "WalkingPadRemote")
        assert not list(args.app.rglob("*.framework")), "Re-audit embedded frameworks"


if __name__ == "__main__":
    main()
