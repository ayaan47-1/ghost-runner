# Ghost Runner

Ghost Runner is an iOS 17 SwiftUI prototype that reads outdoor running workouts and GPS routes from Apple Health, draws the selected route with MapKit, and replays a glowing ghost marker at 1×, 2×, 5×, or 10× speed.

## Requirements

- Xcode 27.1 or newer
- An iOS 17+ simulator for build and logic tests
- A physical iPhone with running workouts containing `HKWorkoutRoute` samples for live HealthKit route testing

## Run

1. Open `GhostRunner.xcodeproj`.
2. Select the `GhostRunner` scheme and an iPhone simulator or device.
3. For a device build, select a development team for the app target.
4. Build and run. Grant read access to Workouts and Workout Routes when prompted.

The simulator can build and run the interface and unit tests, but it normally has no historical Health route data. Use a physical device to verify Garmin-to-Apple-Health route ingestion.

Command-line gates:

```sh
xcodebuild -project GhostRunner.xcodeproj -scheme GhostRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/ghost-runner-derived CODE_SIGNING_ALLOWED=NO build

xcodebuild test -project GhostRunner.xcodeproj -scheme GhostRunner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/ghost-runner-derived CODE_SIGNING_ALLOWED=NO
```

The framework-independent logic can also be tested with:

```sh
swift test --disable-sandbox
```

## HealthKit configuration

`GhostRunner/Info.plist` contains:

- `NSHealthShareUsageDescription`: `Ghost Runner reads your running workouts and routes to replay past runs on a map.`

`GhostRunner/GhostRunner.entitlements` contains:

- `com.apple.developer.healthkit`: `true`

The app requests read-only access to `HKWorkoutType.workoutType()` and `HKSeriesType.workoutRoute()`. It does not write Health data.
