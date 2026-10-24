# iOS App (WalkingPadRemote)

This folder contains the included Xcode project for the iOS WalkingPad app.

## Targets

- `WalkingPadRemote`: iPhone app with treadmill control, HR control, stats, debug, and plank timer flows
- `WorkoutLiveActivity`: Lock Screen and Dynamic Island workout status

## Setup (Xcode)

Build with Xcode 27 or newer (iOS 27 SDK for HealthKit workout zones). The app
continues to support iOS 26.2; zone entry is manual on iOS 26.

1. Open `WalkingPadRemote/WalkingPadRemote.xcodeproj` in Xcode.
2. Select your own signing team for the iPhone and Live Activity targets.
3. Run on a real iPhone with a HealthKit-compatible live heart-rate sensor for HR control.
4. Bluetooth is not available in the iOS Simulator.

## Features

- Manual WalkingPad control and HR-driven speed adaptation.
- Native iPhone HealthKit heart-rate integration.
- Profile-scoped heart-rate zones: manual entry on iOS 26, optional Apple Health import on iOS 27, and optional manual maximum heart rate.
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
- HR control requires fresh live HealthKit measurements. There is no custom watchOS app or direct watch transport; Apple Watch-only live delivery is not guaranteed. Historical Health samples cannot authorize motion.
- Training telemetry can be exported from the in-app Debug tab.
