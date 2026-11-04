# Ghost Runner

<img src="GhostRunner/Assets.xcassets/AppIcon.appiconset/ghost-runner-app-icon-1024.png" width="128" alt="Ghost Runner app icon">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Replay an outdoor Apple Health run on a map and race the moving ghost from that route.

## Features

- Replay a selected outdoor run with a ghost marker on its GPS route.
- Play, pause, choose 1x, 2x, 5x, or 10x speed, drag the scrubber, and recenter the map.
- View completed splits calculated from the route's observed timestamps when the data is available.
- Choose runs in the Runs tab and manage local preferences and Health access in the Account tab.
- Read the welcome guide on first launch or open it again from Account.
- Choose automatic, metric, or imperial units and a default playback speed.
- Use light and dark appearances, plus layouts that adapt to Dynamic Type accessibility sizes.

## Requirements

- iOS 17 or later
- Xcode 16 or later
- A physical iPhone with Apple Health running workouts that include GPS routes

The simulator can run the app and its tests, but it has no historical Health workouts. Use a real iPhone to test workout and route access.

## Build and run

1. Open `GhostRunner.xcodeproj` in Xcode.
2. Select the `GhostRunner` scheme and your iPhone.
3. In **Signing & Capabilities**, choose your development team and set a bundle identifier that you own.
4. Add the HealthKit capability if Xcode has not added it for your signing team.
5. Build and run. Allow Ghost Runner to read Health workouts and workout routes when iOS asks.

For a command-line device build, replace the placeholder values with your team identifier, bundle identifier, and iPhone name:

```sh
xcodebuild build \
  -project GhostRunner.xcodeproj \
  -scheme GhostRunner \
  -destination 'platform=iOS,name=Your iPhone' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.YourGhostRunner
```

The project includes `GhostRunner/GhostRunner.entitlements`, which enables HealthKit. Your signing profile must also support that capability.

## Test

Run the framework-independent logic tests with Swift Package Manager:

```sh
swift test
```

Run the app and logic tests on an installed simulator. Change the destination name if your Xcode installation does not have `iPhone 16 Pro`.

```sh
xcodebuild test \
  -project GhostRunner.xcodeproj \
  -scheme GhostRunner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

## Project structure

```text
GhostRunner/
  Assets.xcassets/          App icon and asset catalog
  ContentView.swift         Tabs, welcome guide, Runs, and Account views
  GhostRunnerMapView.swift  Map replay, controls, and split details
  GhostRunnerViewModel.swift
                            Health data loading and replay state
  HealthKitManager.swift    Read-only HealthKit queries
  Logic/                    Route, playback, split, format, and layout logic
GhostRunnerTests/           Logic tests
GhostRunner.xcodeproj/      Xcode project and app target settings
Package.swift               Swift Package Manager logic-test package
```

## Privacy

Ghost Runner requests read-only HealthKit access. It reads running workouts and workout routes. It does not write Health data.

The app has no network client. It keeps app preferences on the device and does not upload workout or route data.

## License

MIT, see [LICENSE](LICENSE).
