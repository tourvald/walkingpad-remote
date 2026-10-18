#!/usr/bin/env python3
"""Exercise the real adapter's missing-symbol path without requesting health data.

Requires macOS 27 and the Xcode 27 SDK. This host check does not replace iPhone
acceptance. It skips when the host supplies the zone API.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote"

PROBE = """
import Foundation
import HealthKit

@main struct Probe {
    static func main() async throws {
        guard #available(macOS 27.0, *) else {
            print("SKIP: macOS 27 runtime required")
            return
        }
        let store = HKHealthStore()
        if #_hasSymbol(HKWorkoutZoneConfiguration.self),
           #_hasSymbol(HKWorkoutZoneConfiguration.Source.self),
           #_hasSymbol(HKWorkoutZone.self),
           #_hasSymbol(store.preferredWorkoutZoneConfiguration(for:)) {
            print("SKIP: host provides zone symbols; no health read attempted")
            return
        }
        for requestAuthorization in [false, true] {
            do {
                _ = try await AppleHeartRateZoneProvider.read(
                    from: store, requestAuthorization: requestAuthorization
                )
                fatalError("Missing symbols must reject the read")
            } catch AppleHeartRateZoneProvider.ReadError.runtimeUnavailable {
                print("PASS: missing symbols rejected before health access")
            }
        }
    }
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="walkingpad-zone-runtime-") as directory:
        temporary = Path(directory)
        # HealthKit exposes the same Swift zone API on macOS. Adapt only the
        # platform availability annotation; execute the production read path.
        provider = (SOURCES / "AppleHeartRateZoneProvider.swift").read_text()
        (temporary / "Provider.swift").write_text(provider.replace(
            "@available(iOS 27.0, *)", "@available(iOS 27.0, macOS 27.0, *)"
        ))
        (temporary / "Probe.swift").write_text(PROBE)
        for optimization in ["-Onone", "-O"]:
            binary = temporary / "probe"
            subprocess.run([
                "xcrun", "swiftc", "-target", "arm64-apple-macosx26.0",
                "-parse-as-library", optimization,
                str(temporary / "Provider.swift"),
                str(SOURCES / "HeartRateZoneSettings.swift"),
                str(temporary / "Probe.swift"), "-o", str(binary),
            ], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
