import XCTest
#if SWIFT_PACKAGE
@testable import GhostRunnerLogic
#else
@testable import GhostRunner
#endif

final class GhostRunnerLogicTests: XCTestCase {
    func testWelcomeGateShowsBeforeFirstAuthorizationAndCanBeReopened() {
        XCTAssertTrue(WelcomeGate.shouldPresent(hasSeenWelcome: false, reopenRequested: false))
        XCTAssertFalse(WelcomeGate.shouldPresent(hasSeenWelcome: true, reopenRequested: false))
        XCTAssertTrue(WelcomeGate.shouldPresent(hasSeenWelcome: true, reopenRequested: true))
    }

    func testHealthAccessCopyOnlySaysUnavailableForAccessOrWorkoutFetchFailure() {
        XCTAssertEqual(HealthAccessCopy.summary(for: .unavailable), "Health data unavailable")
        XCTAssertEqual(HealthAccessCopy.summary(for: .requested), "Health access requested")
        XCTAssertEqual(HealthAccessCopy.summary(for: .workoutsAvailable), "Health workouts available")
    }

    func testUnitSettingResolvesAutomaticAndExplicitPreferences() {
        XCTAssertEqual(UnitSetting.automatic.resolve(systemUsesMetric: true), .metric)
        XCTAssertEqual(UnitSetting.automatic.resolve(systemUsesMetric: false), .imperial)
        XCTAssertEqual(UnitSetting.metric.resolve(systemUsesMetric: false), .metric)
        XCTAssertEqual(UnitSetting.imperial.resolve(systemUsesMetric: true), .imperial)
    }

    func testRunningTotalsAggregateAllRunsAndCurrentWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
        let runs = [
            RunSummary(startDate: now.addingTimeInterval(-86_400), distanceMetres: 5_000),
            RunSummary(startDate: now.addingTimeInterval(-2 * 86_400), distanceMetres: 12_000),
            RunSummary(startDate: now.addingTimeInterval(-10 * 86_400), distanceMetres: 8_000)
        ]

        let totals = RunningTotals.aggregate(runs: runs, now: now, calendar: calendar)

        XCTAssertEqual(totals.runCount, 3)
        XCTAssertEqual(totals.totalDistanceMetres, 25_000)
        XCTAssertEqual(totals.longestRunMetres, 12_000)
        XCTAssertEqual(totals.thisWeekDistanceMetres, 17_000)
    }

    func testReplayLayoutUsesCompactDockOnShortOrAccessibilityLayouts() {
        XCTAssertEqual(ReplayLayoutPolicy.mode(availableHeight: 844, usesAccessibilitySizes: false), .regular)
        XCTAssertEqual(ReplayLayoutPolicy.mode(availableHeight: 667, usesAccessibilitySizes: false), .compact)
        XCTAssertEqual(ReplayLayoutPolicy.mode(availableHeight: 844, usesAccessibilitySizes: true), .compact)
    }

    func testReplayOverlayGapsMatchDeviceReviewedLayout() {
        XCTAssertEqual(ReplayLayoutMetrics.summaryTopGap, 24)
        XCTAssertEqual(ReplayLayoutMetrics.dockBottomGap, 12)
    }

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

    func testRouteRegionAccountsForReplayOverlays() {
        let region = RouteRegion(
            center: GeoPoint(latitude: 10, longitude: 20),
            latitudeDelta: 1,
            longitudeDelta: 2
        )

        let adjusted = RouteMath.adjustedForViewport(
            region,
            viewportWidth: 400,
            viewportHeight: 800,
            topOcclusion: 150,
            bottomOcclusion: 250,
            horizontalInset: 20
        )

        XCTAssertEqual(adjusted.latitudeDelta, 2, accuracy: 0.000_001)
        XCTAssertEqual(adjusted.longitudeDelta, 2.222_222, accuracy: 0.000_001)
        XCTAssertEqual(adjusted.center.latitude, 9.875, accuracy: 0.000_001)
        XCTAssertEqual(adjusted.center.longitude, 20, accuracy: 0.000_001)
    }

    func testRoutePartsAndSamplesSortChronologicallyWithoutFlattening() {
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

        let ordered = RouteMath.orderedPartsChronologically(parts: parts)
        XCTAssertEqual(ordered.map { $0.map(\.point.longitude) }, [[0, 1], [2, 3]])
    }

    func testOverlappingRoutePartsProduceMonotonicTimelineAndUsableSplits() {
        let timeline = RouteTimeline(parts: [
            [
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0), timestamp: 0),
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0.01), timestamp: 100)
            ],
            [
                TimedRoutePoint(point: GeoPoint(latitude: 1, longitude: 0), timestamp: 50),
                TimedRoutePoint(point: GeoPoint(latitude: 1, longitude: 0.01), timestamp: 60)
            ]
        ])

        XCTAssertEqual(timeline.timestamps, [0, 50, 60, 100])
        XCTAssertTrue(zip(timeline.path.cumulativeDistances, timeline.path.cumulativeDistances.dropFirst())
            .allSatisfy { $0 <= $1 })
        XCTAssertNotNil(SplitMath.completed(
            cumulativeDistances: timeline.path.cumulativeDistances,
            timestamps: timeline.timestamps,
            segmentStartIndices: timeline.path.segmentStartIndices,
            segmentStartDistances: timeline.path.segmentStartDistances,
            units: .metric
        ))
    }

    func testOverlappingRoutePartsNeverMovePlaybackIndexBackward() {
        let path = RouteTimeline(parts: [
            [
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0), timestamp: 0),
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0.01), timestamp: 300)
            ],
            [
                TimedRoutePoint(point: GeoPoint(latitude: 1, longitude: 0), timestamp: 150),
                TimedRoutePoint(point: GeoPoint(latitude: 1, longitude: 0.01), timestamp: 450)
            ]
        ]).path

        XCTAssertEqual(path.index(atDistance: 900), 2)
        XCTAssertEqual(path.index(atDistance: 1_200), 2)
    }

    func testPlaybackProgressIsMonotonicAcrossNormalGapAndOverlappingRoutes() {
        let normal = RoutePath(points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.002),
            GeoPoint(latitude: 0, longitude: 0.01)
        ])
        let gap = RoutePath(parts: [
            [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 0.002)],
            [GeoPoint(latitude: 1, longitude: 0), GeoPoint(latitude: 1, longitude: 0.008)]
        ])
        let overlap = RouteTimeline(parts: [
            [
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0), timestamp: 0),
                TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0.01), timestamp: 300)
            ],
            [
                TimedRoutePoint(point: GeoPoint(latitude: 1, longitude: 0), timestamp: 150),
                TimedRoutePoint(point: GeoPoint(latitude: 1, longitude: 0.01), timestamp: 450)
            ]
        ]).path

        for path in [normal, gap, overlap] {
            let step = 10.0
            var priorIndex = 0
            var priorProgress = 0.0
            var priorGhostDistance = 0.0
            var distance = 0.0

            while true {
                let target = min(distance, path.totalDistance)
                let progress = path.progress(atDistance: target)
                let ghostDistance = path.distance(atProgress: progress)
                let index = path.index(atDistance: target)

                XCTAssertGreaterThanOrEqual(index, priorIndex)
                XCTAssertGreaterThanOrEqual(progress, priorProgress)
                XCTAssertGreaterThanOrEqual(ghostDistance, priorGhostDistance)
                XCTAssertLessThanOrEqual(ghostDistance - priorGhostDistance, step + 0.000_001)

                priorIndex = index
                priorProgress = progress
                priorGhostDistance = ghostDistance
                if target == path.totalDistance { break }
                distance += step
            }
        }
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

    func testSegmentedRouteExcludesAndDoesNotInterpolateAcrossPartGaps() throws {
        let first = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.001)
        ]
        let second = [
            GeoPoint(latitude: 0, longitude: 0.101),
            GeoPoint(latitude: 0, longitude: 0.102)
        ]
        let path = RoutePath(parts: [first, second])

        XCTAssertEqual(path.totalDistance, 222.39, accuracy: 1)
        XCTAssertEqual(path.parts, [first, second])
        XCTAssertEqual(path.cumulativeDistances[1], path.cumulativeDistances[2], accuracy: 0.000_001)
        XCTAssertEqual(path.point(atDistance: path.cumulativeDistances[1]), second[0])
    }

    func testIndexScrubAtPartEndKeepsThatPartsCoordinate() {
        let firstEnd = GeoPoint(latitude: 0, longitude: 0.001)
        let path = RoutePath(parts: [
            [GeoPoint(latitude: 0, longitude: 0), firstEnd],
            [GeoPoint(latitude: 0, longitude: 0.101), GeoPoint(latitude: 0, longitude: 0.102)]
        ])

        XCTAssertEqual(path.point(atIndex: 1), firstEnd)
    }

    func testRoutePlayabilityRejectsSingletonStationaryAndNonfiniteRoutes() {
        XCTAssertFalse(RoutePath(points: [GeoPoint(latitude: 0, longitude: 0)]).isPlayable)
        XCTAssertFalse(RoutePath(points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0)
        ]).isPlayable)
        XCTAssertFalse(RoutePath(points: [
            GeoPoint(latitude: .nan, longitude: 0),
            GeoPoint(latitude: 0, longitude: 1)
        ]).isPlayable)
        XCTAssertTrue(RoutePath(points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.001)
        ]).isPlayable)
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

    func testPlaybackRejectsZeroAndNonfiniteWorkoutDurations() {
        XCTAssertFalse(PlaybackMath.canStart(routeDistance: 1_000, workoutDuration: 0))
        XCTAssertFalse(PlaybackMath.canStart(routeDistance: 1_000, workoutDuration: .nan))
        XCTAssertFalse(PlaybackMath.canStart(routeDistance: 0, workoutDuration: 300))
        XCTAssertTrue(PlaybackMath.canStart(routeDistance: 1_000, workoutDuration: 300))
    }

    func testRoutePathEndpointUsesLastDuplicateSample() {
        let path = RoutePath(points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.001),
            GeoPoint(latitude: 0, longitude: 0.001)
        ])

        XCTAssertEqual(path.index(atDistance: path.totalDistance), 2)
        XCTAssertEqual(path.point(atDistance: path.totalDistance), path.points.last)
    }

    func testCancellationGateFinishesOnlyOnceAndStopsFurtherProjection() {
        var gate = QueryCancellationGate()
        XCTAssertTrue(gate.cancel())
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.canProject)
    }

    func testLoadGenerationRejectsSupersededLoad() {
        var generation = LoadGeneration()
        let first = generation.begin()
        let second = generation.begin()

        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testAutomaticLoadCannotPublishAfterExplicitSelectionStarts() {
        var generation = LoadGeneration()
        let automaticRetry = generation.begin()
        let explicitSelection = generation.begin()

        XCTAssertFalse(generation.isCurrent(automaticRetry))
        XCTAssertTrue(generation.isCurrent(explicitSelection))
    }

    func testInitialRouteSelectionSkipsNewerRunsWithoutRoutes() {
        var selection = InitialRouteSelection(candidateCount: 4)

        XCTAssertEqual(selection.currentCandidateIndex, 0)
        XCTAssertNil(selection.recordCurrent(hasRoute: false))
        XCTAssertEqual(selection.currentCandidateIndex, 1)
        XCTAssertNil(selection.recordCurrent(hasRoute: false))
        XCTAssertEqual(selection.currentCandidateIndex, 2)
        XCTAssertEqual(selection.recordCurrent(hasRoute: true), 2)
        XCTAssertNil(selection.currentCandidateIndex)

        XCTAssertNil(InitialRouteSelection(candidateCount: 0).currentCandidateIndex)
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

    func testCompletedSplitsUseObservedMetricPacesAndExcludePartialSplit() throws {
        let splits = try XCTUnwrap(SplitMath.completed(
            cumulativeDistances: [0, 1_000, 2_000, 2_500],
            timestamps: [0, 300, 660, 800],
            units: .metric
        ))

        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].index, 1)
        XCTAssertEqual(splits[0].secondsPerKilometre, 300, accuracy: 0.000_001)
        XCTAssertEqual(splits[1].secondsPerKilometre, 360, accuracy: 0.000_001)
        XCTAssertEqual(splits[1].elapsedSeconds, 360, accuracy: 0.000_001)
    }

    func testCompletedSplitCacheReturnsPrecomputedResultsForBothUnits() throws {
        let cache = CompletedSplitCache(
            cumulativeDistances: [0, 1_000, 2_000, 3_218.688],
            timestamps: [0, 300, 600, 960]
        )

        XCTAssertEqual(try XCTUnwrap(cache.splits(for: .metric)).count, 3)
        XCTAssertEqual(try XCTUnwrap(cache.splits(for: .imperial)).count, 2)
    }

    func testEmptyReadableRunsAreUnknownRatherThanZeroHistory() {
        XCTAssertEqual(RunningTotalsAvailability.forReadableRunCount(0), .unavailable)
        XCTAssertEqual(RunningTotalsAvailability.forReadableRunCount(1), .available)
    }

    func testElevationGainRejectsFlatAlternatingAltitudeNoise() {
        let points = (0..<1_000).map { index in
            TimedRoutePoint(
                point: GeoPoint(latitude: 0, longitude: Double(index) * 0.000_01),
                altitude: index.isMultiple(of: 2) ? 0 : 1,
                verticalAccuracy: 3,
                timestamp: Double(index)
            )
        }
        XCTAssertEqual(ElevationMath.gain(points: points), 0)
    }

    func testElevationGainRejectsFourMetreOscillationWithinMeasurementUncertainty() {
        let points = (0..<1_000).map { index in
            TimedRoutePoint(
                point: GeoPoint(latitude: 0, longitude: Double(index) * 0.000_1),
                altitude: index.isMultiple(of: 2) ? 0 : 4,
                verticalAccuracy: 3,
                timestamp: Double(index)
            )
        }
        XCTAssertEqual(ElevationMath.gain(points: points), 0)
    }

    func testElevationGainUsesAccurateSustainedClimbs() {
        let points = (0...6).map { index in
            TimedRoutePoint(
                point: GeoPoint(latitude: 0, longitude: Double(index) * 0.000_1),
                altitude: Double(index) * 2,
                verticalAccuracy: 3,
                timestamp: Double(index) * 5
            )
        }
        XCTAssertEqual(try XCTUnwrap(ElevationMath.gain(points: points)), 12, accuracy: 0.1)
    }

    func testElevationGainDoesNotBridgeSeparateRouteParts() {
        let first = [
            TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0), altitude: 0, verticalAccuracy: 3, timestamp: 0),
            TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0.001), altitude: 8, verticalAccuracy: 3, timestamp: 10)
        ]
        let second = [
            TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0.101), altitude: 100, verticalAccuracy: 3, timestamp: 20),
            TimedRoutePoint(point: GeoPoint(latitude: 0, longitude: 0.102), altitude: 108, verticalAccuracy: 3, timestamp: 30)
        ]

        XCTAssertEqual(ElevationMath.gain(parts: [first, second]), 16)
    }

    func testCompletedSplitsUseMileBoundaries() throws {
        let splits = try XCTUnwrap(SplitMath.completed(
            cumulativeDistances: [0, 1_609.344, 3_218.688],
            timestamps: [0, 480, 960],
            units: .imperial
        ))

        XCTAssertEqual(splits.map(\.index), [1, 2])
        XCTAssertEqual(splits[0].startDistance, 0, accuracy: 0.000_001)
        XCTAssertEqual(splits[1].startDistance, 1_609.344, accuracy: 0.000_001)
    }

    func testCompletedSplitsAreUnavailableWithoutReliableTimestamps() {
        XCTAssertNil(SplitMath.completed(
            cumulativeDistances: [0, 1_000],
            timestamps: nil,
            units: .metric
        ))
        XCTAssertNil(SplitMath.completed(
            cumulativeDistances: [0, 1_000],
            timestamps: [10, 5],
            units: .metric
        ))
        XCTAssertEqual(SplitMath.completed(
            cumulativeDistances: [0, 100, 1_000],
            timestamps: [0, 30, 10_000],
            units: .metric
        ), [])
    }

    func testCompletedSplitsExcludeStationaryBoundaryTime() throws {
        let splits = try XCTUnwrap(SplitMath.completed(
            cumulativeDistances: [0, 1_000, 1_000, 2_000],
            timestamps: [0, 300, 600, 900],
            units: .metric
        ))

        XCTAssertEqual(splits.map(\.secondsPerKilometre), [300, 300])
        XCTAssertEqual(splits.map(\.elapsedSeconds), [300, 300])
    }

    func testDenseRunningSamplesRemainMoving() throws {
        let sampleCount = 1_335
        let distances = (0..<sampleCount).map { Double($0) * 0.75 }
        let timestamps = (0..<sampleCount).map { Double($0) * 0.25 }

        let splits = try XCTUnwrap(SplitMath.completed(
            cumulativeDistances: distances,
            timestamps: timestamps,
            units: .metric
        ))
        let current = SplitMath.current(
            atDistance: 1_000,
            cumulativeDistances: distances,
            timestamps: timestamps,
            units: .metric,
            averageSecondsPerKilometre: 420
        )

        let split = try XCTUnwrap(splits.first)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(split.secondsPerKilometre, 1_000 / 3, accuracy: 0.001)
        XCTAssertEqual(current.source, .previous)
        XCTAssertEqual(current.secondsPerKilometre, 1_000 / 3, accuracy: 0.001)
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

    func testPaceDisplaySeparatesValueFromUnitFor402PointReplayStats() {
        XCTAssertEqual(
            RunFormatting.paceDisplay(secondsPerKilometre: 560.5, units: .imperial),
            PaceDisplay(value: "15:02", unit: "/mi")
        )

        let split = CurrentSplit(index: 1, secondsPerKilometre: 560.5, source: .average)
        XCTAssertEqual(
            RunFormatting.currentSplitDisplay(split, units: .imperial),
            CurrentSplitDisplay(context: "Mi 1 · avg", pace: "15:02", unit: "/mi")
        )
    }

    func testPaceDisplayCapsValuesThatCannotFitReplayStats() {
        XCTAssertEqual(
            RunFormatting.paceDisplay(secondsPerKilometre: 6_000, units: .metric),
            PaceDisplay(value: ">99:59", unit: "/km")
        )
        XCTAssertEqual(
            RunFormatting.paceDisplay(secondsPerKilometre: 3_728, units: .imperial),
            PaceDisplay(value: ">99:59", unit: "/mi")
        )
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
