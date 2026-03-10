# iOS App (WalkingPadRemote)

This folder contains the included Xcode project for the iOS/watchOS WalkingPad app.

## Targets

- `WalkingPadRemote`: iPhone app with treadmill control, HR control, stats, debug, and plank timer flows
- `WalkingPadRemoteWatch Watch App`: watch companion used for heart-rate streaming

## Setup (Xcode)

1. Open `WalkingPadRemote/WalkingPadRemote.xcodeproj` in Xcode.
2. Select your own signing team for the iOS and watchOS targets.
3. Run on a real iPhone paired with Apple Watch if you need HR control.
4. Bluetooth is not available in the iOS Simulator.

## Features

- Manual WalkingPad control and HR-driven speed adaptation.
- Apple Watch heart-rate integration.
- Workout statistics and telemetry export.
- Plank timer tab with progression settings.

## Validation

Run the checks that are safe to execute without personal signing:

```bash
cd WalkingPadRemote
swift test
cd ..
xcodebuild -project WalkingPadRemote/WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Notes

- Only one device can be connected to the belt at a time.
- If the app cannot connect, make sure the belt is not connected to another phone/app.
- Bluetooth is not available in the iOS Simulator.
- HR control requires a real Apple Watch session; the watch app is optional for non-HR flows.
- Training telemetry can be exported from the in-app Debug tab.
