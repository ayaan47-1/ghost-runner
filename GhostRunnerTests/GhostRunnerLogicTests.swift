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
