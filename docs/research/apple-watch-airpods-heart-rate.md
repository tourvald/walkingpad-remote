# Apple Watch and AirPods Pro 3 heart-rate sources

Research date: 2026-05-06

## Question

Can WalkingPad Remote use heart-rate data from both Apple Watch and AirPods Pro 3, and how does Apple handle simultaneous heart-rate streams?

## Current app behavior

WalkingPad Remote currently has one live heart-rate source:

```text
Apple Watch app
  -> HKWorkoutSession / HKLiveWorkoutBuilder on watchOS
  -> WCSession payload ["hr": Double]
  -> BluetoothManager.heartRateBPM on iPhone
```

The iPhone app does not currently start a local `HKWorkoutSession` for heart-rate collection. It also does not read the BLE Heart Rate Service (`180D` / `2A37`) directly.

## Confirmed Apple behavior

AirPods Pro 3 have in-ear heart-rate sensors and can provide heart-rate data during workouts.

Apple documents that AirPods Pro 3 heart-rate data can appear in:

- Fitness app workouts on iPhone.
- Apple Fitness+ workouts.
- Supported third-party workout apps on iPhone or iPad.
- Health app workout details after the workout.

Apple also documents that when Apple Watch and AirPods Pro 3 are both worn during a workout, they provide multiple heart-rate streams and Apple automatically uses the highest-confidence source in the moment.

Important interpretation: Apple does not describe this as a simple average. The documented behavior is source selection by confidence.

## HealthKit behavior relevant to iPhone workouts

Starting with the current HealthKit workout APIs for iOS/iPadOS, an app can run a workout session on iPhone or iPad using `HKWorkoutSession` and `HKLiveWorkoutBuilder`.

Apple states that iPhone and iPad do not have built-in heart-rate sensors. To collect heart rate during an iPhone/iPad workout, the user must have a paired external heart-rate sensor. Apple examples mention heart-rate GATT-profile devices. AirPods Pro 3 fit the product-level support path documented for Fitness and supported third-party workout apps.

For an iPhone-side workout, the expected data path is:

```text
iPhone app
  -> HKWorkoutSession / HKLiveWorkoutBuilder on iOS
  -> HealthKit receives HR from external source, such as AirPods Pro 3
  -> live builder delegate observes heartRate
  -> BluetoothManager.heartRateBPM
```

This is different from the current watch-side flow.

## Apple Watch and iPhone workout mirroring

Apple also provides HealthKit mirrored workout sessions for Apple Watch + iPhone apps.

In that model:

```text
Apple Watch workout session = primary session
iPhone workout session = mirrored session
```

HealthKit keeps the primary and mirrored session state in sync. The iPhone app can be launched in the background when a watch workout starts, receive the mirrored session, and exchange app-defined workout data with the watch using remote workout session APIs.

This explains the user-visible behavior where starting a workout on Apple Watch can make the iPhone show the active workout. That should be treated as mirroring/continuity, not necessarily as two independent workouts.

## What is not clearly documented

I did not find a public Apple API that lets a third-party app directly ask:

- "Was this live heart-rate quantity from Apple Watch or AirPods?"
- "What is the confidence value Apple used for this sample?"
- "Force AirPods over Watch" or "force Watch over AirPods" for HealthKit's live workout source selection.
- "How exactly does Apple compute the highest-confidence source?"

HealthKit saved samples can have source metadata, but `HKLiveWorkoutBuilder` commonly exposes live values through builder statistics, not as raw per-source samples. For the WalkingPad control loop, source identity and latency would need device testing.

## Highest-confidence algorithm lookup

I did not find a public Apple document that discloses the algorithm or scoring formula behind "highest-confidence source." Public Apple documentation confirms the behavior but not the implementation.

Known public inputs/factors from Apple documentation:

- AirPods Pro 3: fit/contact in the ear, clean sensors, cold/weather and skin blood flow, earwax/moisture/skin conditions/piercings, and individual skin blood-flow differences can affect readings.
- Apple Watch: fit on wrist, wrist detection, skin perfusion, tattoos, motion type, and workout type can affect reading reliability.
- Apple Watch optical HR can compensate for low signal by changing LED brightness and sampling rate.
- Apple Watch uses green LEDs for workout HR and infrared for background HR/notifications.
- HealthKit heart-rate samples may include motion context metadata (`HKMetadataKeyHeartRateMotionContext`) and sensor location metadata (`HKMetadataKeyHeartRateSensorLocation`).
- HealthKit samples have source/source revision information, which can represent a device such as Apple Watch or a Bluetooth LE heart-rate monitor.

Practical conclusion: Apple likely computes confidence using private sensor-quality and sensor-fusion signals that third-party apps do not receive directly. For this project, do not depend on reproducing Apple's exact algorithm.

## Implication for third-party heart-rate monitors

There are two viable strategies:

1. Let HealthKit own source selection where possible.
   - If the sensor is paired to iPhone/watchOS in a way HealthKit supports, run a HealthKit workout and consume live `heartRate`.
   - This may let Apple choose the best available source, including AirPods Pro 3 + Apple Watch combinations.
   - Limitation: source identity and confidence may not be exposed in the live builder callback.

2. Build a project-owned confidence score for direct BLE sources.
   - Needed if WalkingPad Remote reads multiple BLE HR devices directly.
   - This score should be transparent, logged, and conservative because treadmill speed decisions depend on it.

Suggested project-owned confidence inputs:

- sample freshness: reject samples older than the active HR threshold;
- continuity: prefer sources with stable recent delivery cadence;
- validity: reject impossible values and large physiologically implausible jumps;
- source reliability tier: chest straps usually outrank optical wrist/ear during high-motion workouts unless stale;
- sensor location: use HealthKit `HKMetadataKeyHeartRateSensorLocation` or BLE/device metadata when available;
- motion/workout context: prefer sensors known to perform better for the current activity;
- agreement: boost confidence when independent sources agree within a small bpm window;
- dropouts: penalize recent missing samples or repeated flatlines;
- latency: prefer lower sample age for control-loop decisions;
- user override: allow explicit preferred source for debugging and safety.

This should be logged per sample:

```text
hr_source
hr_source_device_name
hr_source_transport
hr_sampled_at
hr_received_at
hr_sample_age_ms
hr_confidence_score
hr_confidence_reasons
hr_selected
```

The algorithm should choose a single source for the current control decision, not average multiple sources by default. Averaging can hide sensor faults; for treadmill control, explicit source selection is easier to debug and safer to reason about.

## Practical architecture options

### Option A: explicit source modes

Add a user-visible heart-rate source mode:

```swift
enum HeartRateSourceMode {
    case appleWatchApp
    case iPhoneHealthKit
    case auto
}
```

`appleWatchApp` keeps the current watch app + `WCSession` path.

`iPhoneHealthKit` starts a local iPhone `HKWorkoutSession`; this is the right mode for AirPods Pro 3 and other iPhone-paired HR sensors.

`auto` can be introduced after real-device testing.

This is the lowest-risk implementation path.

### Option B: iPhone HealthKit as Apple-managed fused source

For AirPods Pro 3 support, a strong candidate is to let the iPhone app run a HealthKit workout and consume `heartRate` from the live builder. If the user wears both AirPods Pro 3 and Apple Watch, Apple's documented behavior suggests HealthKit/Fitness can use the highest-confidence stream.

This should be prototyped on real devices because the exact live data source visibility is not documented at the app level.

### Option C: HealthKit mirrored workout session

Longer term, the app could replace the custom watch HR transport with HealthKit mirrored workout sessions:

- iPhone requests/receives a mirrored watch workout.
- HealthKit syncs workout session state between devices.
- The app uses HealthKit remote workout APIs for structured communication instead of ad-hoc `WCSession` HR payloads.

This is more aligned with Apple's workout architecture, but it is a larger refactor.

### Option D: manually fuse watch and iPhone HR streams

The app could keep the current watch HR stream and add a second iPhone HealthKit stream, then choose between them itself.

This is not recommended as the first implementation because it risks:

- duplicate workout sessions;
- conflicting HealthKit records;
- unclear source confidence;
- more failure modes in the treadmill safety loop.

## Recommendation for WalkingPad Remote

Implement AirPods Pro 3 support as an iPhone-side HealthKit HR provider first.

Do not start the current watch HR session and a local iPhone workout session at the same time by default. Instead:

1. Keep the current Apple Watch mode unchanged.
2. Add an iPhone HealthKit mode for AirPods Pro 3 and other external HR sensors.
3. Route both modes into one internal sample model:

```swift
struct HeartRateSample {
    let bpm: Int
    let sampledAt: Date
    let receivedAt: Date
    let source: HeartRateSource
}
```

4. Add telemetry fields for source, sample age, and delivery path.
5. Test a third "auto/fused" mode on real devices with Apple Watch + AirPods Pro 3 before making it the default.

## Open validation checklist

Before implementation is considered stable, test on physical devices:

- AirPods Pro 3 only, workout started from WalkingPad Remote on iPhone.
- Apple Watch only, current watch app path.
- Apple Watch + AirPods Pro 3, workout started from iPhone HealthKit path.
- Apple Watch + AirPods Pro 3, workout started from watch/mirrored path if we prototype mirroring.
- iPhone locked during workout.
- AirPods poor fit / HR dashes case.
- Watch temporarily unreachable.
- AirPods audio connected to another Apple device while iPhone receives HR.

## Sources

- Apple Support: Track your heart rate during workouts with AirPods Pro 3  
  https://support.apple.com/guide/airpods/track-heart-rate-workouts-airpods-pro-3-dev1b40fb47d/web

- Apple Support: How to check your heart rate with AirPods Pro 3  
  https://support.apple.com/en-us/123184

- Apple Developer: WWDC25, Track workouts with HealthKit on iOS and iPadOS  
  https://developer.apple.com/videos/play/wwdc2025/322/

- Apple Developer: Building a workout app for iPhone and iPad  
  https://developer.apple.com/documentation/HealthKit/building-a-workout-app-for-iphone-and-ipad

- Apple Developer: HKWorkoutSession  
  https://developer.apple.com/documentation/healthkit/hkworkoutsession

- Apple Developer: HKLiveWorkoutBuilder  
  https://developer.apple.com/documentation/HealthKit/HKLiveWorkoutBuilder

- Apple Developer: WWDC23, Build a multi-device workout app  
  https://developer.apple.com/videos/play/wwdc2023/10023

- Apple Developer: Building a multidevice workout app  
  https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app

- Apple Developer: workoutSessionMirroringStartHandler  
  https://developer.apple.com/documentation/healthkit/hkhealthstore/workoutsessionmirroringstarthandler

- Apple Developer: workoutSession(_:didReceiveDataFromRemoteWorkoutSession:)  
  https://developer.apple.com/documentation/healthkit/hkworkoutsessiondelegate/workoutsession(_:didreceivedatafromremoteworkoutsession:)
