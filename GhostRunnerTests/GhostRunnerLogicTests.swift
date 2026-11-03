import XCTest
#if SWIFT_PACKAGE
@testable import GhostRunnerLogic
#else
@testable import GhostRunner
#endif

final class GhostRunnerLogicTests: XCTestCase {
    func testRouteRegionFitsBoundsWithPadding() throws {
        let points = [
            GeoPoint(latitude: 37.0, longitude: -122.2),
            GeoPoint(latitude: 37.2, longitude: -121.8)
        ]

        let region = try XCTUnwrap(RouteMath.fittedRegion(for: points, paddingFactor: 1.25))

        XCTAssertEqual(region.center.latitude, 37.1, accuracy: 0.000_001)
        XCTAssertEqual(region.center.longitude, -122.0, accuracy: 0.000_001)
        XCTAssertEqual(region.latitudeDelta, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(region.longitudeDelta, 0.5, accuracy: 0.000_001)
    }

    func testRouteRegionUsesMinimumSpanForOnePoint() throws {
        let region = try XCTUnwrap(RouteMath.fittedRegion(
            for: [GeoPoint(latitude: 51.5, longitude: -0.12)],
            paddingFactor: 1.25,
            minimumSpan: 0.002
        ))

        XCTAssertEqual(region.center, GeoPoint(latitude: 51.5, longitude: -0.12))
        XCTAssertEqual(region.latitudeDelta, 0.002)
        XCTAssertEqual(region.longitudeDelta, 0.002)
    }

    func testRouteRegionIsNilForEmptyRoute() {
        XCTAssertNil(RouteMath.fittedRegion(for: []))
    }

    func testRouteRegionUsesShortestSpanAcrossDateLine() throws {
        let region = try XCTUnwrap(RouteMath.fittedRegion(for: [
            GeoPoint(latitude: 10, longitude: 179.9),
            GeoPoint(latitude: 10.1, longitude: -179.9)
        ]))

        XCTAssertEqual(abs(region.center.longitude), 180, accuracy: 0.000_001)
        XCTAssertEqual(region.longitudeDelta, 0.25, accuracy: 0.000_001)
    }

    func testRoutePartsAndSamplesMergeChronologically() {
        let parts = [
            [
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 3), timestamp: 3),
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 2), timestamp: 2)
            ],
            [
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 1), timestamp: 1),
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0), timestamp: 0)
            ]
        ]

        XCTAssertEqual(
            RouteMath.mergedChronologically(parts: parts).map(\.point.longitude),
            [0, 1, 2, 3]
        )
    }

    func testRoutePathInterpolatesByPhysicalDistanceOnSparseSegments() throws {
        let path = RoutePath(points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.001),
            GeoPoint(latitude: 0, longitude: 0.010)
        ])

        let halfway = try XCTUnwrap(path.point(atDistance: path.totalDistance / 2))

        XCTAssertEqual(halfway.latitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(halfway.longitude, 0.005, accuracy: 0.000_01)
    }

    func testPlaybackAdvancesAtSupportedSpeeds() {
        let expectations = [(1.0, 6), (2.0, 12), (5.0, 30), (10.0, 60)]
        for (speed, expected) in expectations {
            XCTAssertEqual(
                PlaybackMath.advancedIndex(
                    from: 0,
                    elapsed: 0.5,
                    speed: speed,
                    pointsPerSecond: 12,
                    routeCount: 100
                ),
                expected
            )
        }
    }

    func testPlaybackClampsAtLastCoordinate() {
        XCTAssertEqual(
            PlaybackMath.advancedIndex(
                from: 8,
                elapsed: 1,
                speed: 10,
                pointsPerSecond: 12,
                routeCount: 10
            ),
            9
        )
    }

    func testPlaybackHandlesEmptyRoute() {
        XCTAssertEqual(
            PlaybackMath.advancedIndex(
                from: 3,
                elapsed: 1,
                speed: 1,
                pointsPerSecond: 12,
                routeCount: 0
            ),
            0
        )
    }

    func testPlaybackAdvancesDistanceFromAveragePaceAndSpeed() {
        XCTAssertEqual(
            PlaybackMath.advancedDistance(
                from: 100,
                elapsed: 10,
                speed: 2,
                routeDistance: 1_000,
                workoutDuration: 500
            ),
            140,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PlaybackMath.advancedDistance(
                from: 990,
                elapsed: 10,
                speed: 1,
                routeDistance: 1_000,
                workoutDuration: 500
            ),
            1_000,
            accuracy: 0.000_001
        )
    }

    func testSelectionGenerationRejectsSupersededLoad() {
        var generation = SelectionGeneration()
        let first = generation.begin()
        let second = generation.begin()

        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testCurrentSplitUsesRealTimestampsForSplitIndexAndPace() {
        let split = SplitMath.current(
            atDistance: 1_500,
            cumulativeDistances: [0, 500, 1_000, 1_500, 2_000],
            timestamps: [0, 120, 240, 420, 600],
            units: .metric,
            averageSecondsPerKilometre: 300
        )

        XCTAssertEqual(split.index, 2)
        XCTAssertEqual(split.secondsPerKilometre, 360, accuracy: 0.000_001)
        XCTAssertEqual(split.source, .actual)
        XCTAssertEqual(RunFormatting.currentSplit(split, units: .metric), "Km 2 · 6:00 /km")
    }

    func testCurrentSplitUsesKilometreAndMileBoundaries() {
        XCTAssertEqual(
            SplitMath.current(
                atDistance: 1_000,
                cumulativeDistances: [0, 1_000, 2_000],
                timestamps: [0, 300, 600],
                units: .metric,
                averageSecondsPerKilometre: 300
            ).index,
            2
        )
        XCTAssertEqual(
            SplitMath.current(
                atDistance: 1_609.344,
                cumulativeDistances: [0, 1_609.344, 3_218.688],
                timestamps: [0, 480, 960],
                units: .imperial,
                averageSecondsPerKilometre: 298.258_172,
            ).index,
            2
        )
    }

    func testCurrentSplitFallsBackToPreviousSplitAtStartOfNextSplit() {
        let split = SplitMath.current(
            atDistance: 1_050,
            cumulativeDistances: [0, 1_000, 1_050, 2_000],
            timestamps: [0, 300, 310, 600],
            units: .metric,
            averageSecondsPerKilometre: 330
        )

        XCTAssertEqual(split.index, 2)
        XCTAssertEqual(split.secondsPerKilometre, 300, accuracy: 0.000_001)
        XCTAssertEqual(split.source, .previous)
    }

    func testCurrentSplitUsesShortRollingWindowDuringFirstSplit() {
        let split = SplitMath.current(
            atDistance: 50,
            cumulativeDistances: [0, 50, 1_000],
            timestamps: [0, 25, 500],
            units: .metric,
            averageSecondsPerKilometre: 600
        )

        XCTAssertEqual(split.secondsPerKilometre, 500, accuracy: 0.000_001)
        XCTAssertEqual(split.source, .rolling)
    }

    func testCurrentSplitClearlyFallsBackToAverageWithoutTimestamps() {
        let split = SplitMath.current(
            atDistance: 1_250,
            cumulativeDistances: [0, 1_000, 2_000],
            timestamps: nil,
            units: .metric,
            averageSecondsPerKilometre: 305
        )

        XCTAssertEqual(split.index, 2)
        XCTAssertEqual(split.secondsPerKilometre, 305, accuracy: 0.000_001)
        XCTAssertEqual(split.source, .average)
        XCTAssertEqual(RunFormatting.currentSplit(split, units: .metric), "Km 2 · avg 5:05 /km")
    }

    func testCurrentSplitRejectsZeroDistanceAndAbsurdPausedPace() {
        let noMovement = SplitMath.current(
            atDistance: 0,
            cumulativeDistances: [0, 0, 0],
            timestamps: [0, 100, 200],
            units: .metric,
            averageSecondsPerKilometre: 320
        )
        let longPause = SplitMath.current(
            atDistance: 1_000,
            cumulativeDistances: [0, 1_000],
            timestamps: [0, 5_000],
            units: .metric,
            averageSecondsPerKilometre: 320
        )

        XCTAssertEqual(noMovement.source, .average)
        XCTAssertEqual(noMovement.secondsPerKilometre, 320)
        XCTAssertEqual(longPause.source, .average)
        XCTAssertEqual(longPause.secondsPerKilometre, 320)
    }

    func testCurrentSplitExcludesPauseAtSplitBoundaryFromCurrentPace() {
        let split = SplitMath.current(
            atDistance: 1_500,
            cumulativeDistances: [0, 1_000, 1_000, 2_000],
            timestamps: [0, 300, 600, 900],
            units: .metric,
            averageSecondsPerKilometre: 450
        )

        XCTAssertEqual(split.index, 2)
        XCTAssertEqual(split.source, .actual)
        XCTAssertEqual(split.secondsPerKilometre, 300, accuracy: 0.000_001)
    }

    func testCurrentSplitExcludesPauseInMiddleOfSplit() {
        let split = SplitMath.current(
            atDistance: 750,
            cumulativeDistances: [0, 500, 500, 1_000],
            timestamps: [0, 150, 450, 600],
            units: .metric,
            averageSecondsPerKilometre: 600
        )

        XCTAssertEqual(split.source, .actual)
        XCTAssertEqual(split.secondsPerKilometre, 300, accuracy: 0.000_001)
    }

    func testCurrentSplitExcludesPauseAtEndOfCompletedSplit() {
        let split = SplitMath.current(
            atDistance: 1_000,
            cumulativeDistances: [0, 1_000, 1_000, 2_000],
            timestamps: [0, 300, 600, 900],
            units: .metric,
            averageSecondsPerKilometre: 450
        )

        XCTAssertEqual(split.index, 2)
        XCTAssertEqual(split.source, .previous)
        XCTAssertEqual(split.secondsPerKilometre, 300, accuracy: 0.000_001)
    }

    func testScrubberClampsAndRoundsToCoordinate() {
        XCTAssertEqual(PlaybackMath.scrubbedIndex(for: -4, routeCount: 20), 0)
        XCTAssertEqual(PlaybackMath.scrubbedIndex(for: 6.6, routeCount: 20), 7)
        XCTAssertEqual(PlaybackMath.scrubbedIndex(for: 99, routeCount: 20), 19)
        XCTAssertEqual(PlaybackMath.scrubbedIndex(for: 4, routeCount: 0), 0)
    }

    func testDistanceFormattingSupportsKilometresAndMiles() {
        XCTAssertEqual(RunFormatting.distance(metres: 5_000, units: .metric), "5.00 km")
        XCTAssertEqual(RunFormatting.distance(metres: 5_000, units: .imperial), "3.11 mi")
    }

    func testPaceFormattingSupportsKilometresAndMiles() {
        XCTAssertEqual(RunFormatting.pace(secondsPerKilometre: 300, units: .metric), "5:00 /km")
        XCTAssertEqual(RunFormatting.pace(secondsPerKilometre: 300, units: .imperial), "8:03 /mi")
    }

    func testPaceFormattingHandlesMissingValues() {
        XCTAssertEqual(RunFormatting.pace(secondsPerKilometre: nil, units: .metric), "—")
        XCTAssertEqual(RunFormatting.pace(secondsPerKilometre: 0, units: .metric), "—")
    }

    func testDurationFormatting() {
        XCTAssertEqual(RunFormatting.duration(seconds: 2_525), "42:05")
        XCTAssertEqual(RunFormatting.duration(seconds: 3_723), "1:02:03")
        XCTAssertEqual(RunFormatting.duration(seconds: -1), "0:00")
    }

    func testElevationFormattingSupportsMetresAndFeet() {
        XCTAssertEqual(RunFormatting.elevationGain(metres: 123.4, units: .metric), "123 m")
        XCTAssertEqual(RunFormatting.elevationGain(metres: 123.4, units: .imperial), "405 ft")
        XCTAssertEqual(RunFormatting.elevationGain(metres: nil, units: .metric), "—")
    }
}
