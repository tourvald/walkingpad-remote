# Required-reason API audit (#237)

Baseline: `870a8511b5bf848d1ebc4c94702987bd59db9828`. Audit date: 2026-10-18.
Scope: Release iOS app, Live Activity extension and their
linked local-package code. No external Swift package or vendored binary SDK is
linked. Apple system frameworks are platform dependencies, not redistributed SDKs.

| Consuming executable | API / source owner | Declaration and reason |
| --- | --- | --- |
| iOS app | `UserDefaults`, SwiftUI `@AppStorage`: BluetoothManager profiles/settings/device preferences, ContentView navigation, PlankTimerView; TelemetryPersistence legacy-source discovery | UserDefaults `CA92.1`: app-private preferences only, no App Group or managed/global preferences |
| iOS app | `ProcessInfo.systemUptime`: BluetoothManager treadmill test-run scheduling | SystemBootTime `35F9.1`: elapsed intervals/timers within the app; only elapsed test-run progress enters telemetry, no raw system uptime |
| iOS app | `URLResourceKey.contentModificationDateKey`: TelemetryRuntime DiagnosticZipArchive | FileTimestamp `C617.1`: metadata of app-managed temporary diagnostic files used for ZIP entries |
| Live Activity extension | WorkoutLiveActivityWidget + WorkoutActivityAttributes | No required-reason API found; empty API list |

The local Swift package is statically linked into the iOS executable, so the
consuming app manifest covers its required-reason calls. TelemetrySoak / CLI,
tests and nonshipping `STOP_TRUTH_EXPERIMENT_CAPABILITY` paths are not release
products. DispatchTime is used for monotonic elapsed timing; it is not one of
Apple's listed required-reason API entry points. No covered disk-capacity or
active-keyboard APIs were found in shipped sources. File size alone is not an
additional API category. Re-audit when targets, dependencies, usage or Apple
reasons change; this inventory is not a general SDK certification.

Each target has its own `PrivacyInfo.xcprivacy`. The synchronized iOS group
include resources automatically. The explicit Live Activity group has a focused
resource build phase. SwiftPM core tests exclude the iOS app manifest; no new
package resource bundle or runtime owner is necessary. All manifests declare
tracking false and no tracking domains. #238 subsequently approved retained
customer-support receipt of user-selected diagnostics/messages. The iPhone app
manifest now declares Health, Fitness, Name, EmailAddress, UserID, CustomerSupport
and OtherDiagnosticData, linked to identity, for AppFunctionality and not tracking.
This matches the prepared App Privacy worksheet; absence of an automatic uploader
is not an exemption. The Live Activity bundle has no support/share
entry or independent developer-collection path and retains an empty collected-type
array. Health data in phone-submitted files is covered by the iPhone disclosure.
The custom Watch bundle and its direct transport have been removed.

## Verification and release gates

- Run `python3 scripts/check_privacy_manifests.py` for source manifests.
- Build with `xcodebuild -project ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/wp-privacy-release CODE_SIGNING_ALLOWED=NO build`.
- Run `python3 scripts/check_privacy_manifests.py --app /tmp/wp-privacy-release/Build/Products/Release-iphoneos/WalkingPadRemote.app` to check the actual embedded bundles against source declarations.
- Run the Swift package suite. CI stays disabled for the approved batch.
- **UNVERIFIED release gates:** signed distribution archive and Organizer/App Store
  Connect validation; physical iPhone navigation/privacy checks. No device install,
  signing changes or App Store submission is performed by this task. An unsigned
  build and plist checks do not prove App Review acceptance.

## Official references

Checked 2026-10-18: [required-reason API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype),
[per-executable declaration requirement](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
[manifest placement and resource membership](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).
Apple requires a declaration in the bundle containing each executable using a
covered API; declarations must describe actual usage rather than a generic list.

#238 correction reference: [TN3184](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest) and [describing data use](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests), checked 2026-10-18. Declare every collected type using Apple-defined values; the checker verifies bundle-specific type/link/purpose/tracking declarations, not merely the required-reason list.
