@preconcurrency import HealthKit
import CoreLocation
import Foundation
import Observation

@Observable
@MainActor
final class GhostRunnerViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case empty(title: String, message: String)
        case failed(String)
    }

    let playbackSpeeds = [1.0, 2.0, 5.0, 10.0]

    private(set) var recentRuns: [HKWorkout] = []
    var selectedWorkout: HKWorkout?
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var routeCoordinateParts: [[CLLocationCoordinate2D]] = []
    private(set) var ghostCoordinate: CLLocationCoordinate2D?
    private(set) var elevationGainMetres: Double?
    private(set) var isPlaying = false
    var playbackSpeed = 1.0
    var loadState: LoadState = .idle
    var isSplitsPresented = false
    var isWelcomeGuidePresented = false
    var unitSetting: UnitSetting = .automatic
    private(set) var defaultPlaybackSpeed = 1.0
    private(set) var runningTotals = RunningTotals.empty
    private(set) var isRunningTotalsLoading = false
    private(set) var runningTotalsError: String?
    private(set) var healthAccessState: HealthAccessState = .notRequested
    private(set) var selectedSplitIndex: Int?
    private(set) var routePresentationID: UInt64 = 0

    private let healthKitManager: HealthKitManager
    private var playbackTask: Task<Void, Never>?
    private var routeLoadTask: Task<WorkoutRouteData, Error>?
    private var routeLoadToken: UInt64 = 0
    private var playbackDistance = 0.0
    private var routePath = RoutePath(points: [])
    private var routeTimestamps: [TimeInterval]?
    private var completedSplitCache = CompletedSplitCache(cumulativeDistances: [], timestamps: nil)
    private var loadGeneration = LoadGeneration()
    private var routePresentationGeneration = LoadGeneration()

    init(healthKitManager: HealthKitManager = HealthKitManager()) {
        self.healthKitManager = healthKitManager
    }

    var scrubberValue: Double {
        get { routePath.progress(atDistance: playbackDistance) }
        set { scrub(to: newValue) }
    }

    var maximumScrubberValue: Double {
        Double(max(1, routeCoordinates.count - 1))
    }

    var unitPreference: UnitPreference {
        unitSetting.resolve(systemUsesMetric: Locale.current.measurementSystem == .metric)
    }

    var formattedDistance: String {
        RunFormatting.distance(
            metres: selectedWorkout?.totalDistance?.doubleValue(for: .meter()) ?? 0,
            units: unitPreference
        )
    }

    var formattedDuration: String {
        RunFormatting.duration(seconds: selectedWorkout?.duration ?? 0)
    }

    var formattedPace: String {
        RunFormatting.pace(secondsPerKilometre: averageSecondsPerKilometre, units: unitPreference)
    }

    var paceDisplay: PaceDisplay {
        RunFormatting.paceDisplay(secondsPerKilometre: averageSecondsPerKilometre, units: unitPreference)
    }

    var formattedCurrentSplit: String {
        RunFormatting.currentSplit(currentSplit, units: unitPreference)
    }

    var currentSplitDisplay: CurrentSplitDisplay {
        RunFormatting.currentSplitDisplay(currentSplit, units: unitPreference)
    }

    private var currentSplit: CurrentSplit {
        SplitMath.current(
            atDistance: playbackDistance,
            cumulativeDistances: routePath.cumulativeDistances,
            timestamps: routeTimestamps,
            segmentStartIndices: routePath.segmentStartIndices,
            segmentStartDistances: routePath.segmentStartDistances,
            units: unitPreference,
            averageSecondsPerKilometre: averageSecondsPerKilometre ?? 0
        )
    }

    private var averageSecondsPerKilometre: Double? {
        guard let workout = selectedWorkout,
              let metres = workout.totalDistance?.doubleValue(for: .meter()),
              metres > 0 else {
            return nil
        }
        return workout.duration / (metres / 1_000)
    }

    var formattedElevationGain: String {
        RunFormatting.elevationGain(metres: elevationGainMetres, units: unitPreference)
    }

    var observedSplits: [ObservedSplit]? {
        completedSplitCache.splits(for: unitPreference)
    }

    var healthAccessSummary: String {
        HealthAccessCopy.summary(for: healthAccessState)
    }

    var shouldOfferHealthSettings: Bool {
        healthAccessState == .requested || healthAccessState == .unavailable
    }

    func applyPreferences(unitSetting: UnitSetting, defaultPlaybackSpeed: Double) {
        self.unitSetting = unitSetting
        let speed = playbackSpeeds.contains(defaultPlaybackSpeed) ? defaultPlaybackSpeed : 1
        self.defaultPlaybackSpeed = speed
        if !isPlaying {
            playbackSpeed = speed
        }
    }

    func loadRunningTotals() async {
        guard !isRunningTotalsLoading else { return }
        isRunningTotalsLoading = true
        runningTotalsError = nil
        defer { isRunningTotalsLoading = false }
        do {
            let workouts = try await healthKitManager.fetchAllRuns()
            guard RunningTotalsAvailability.forReadableRunCount(workouts.count) == .available else {
                healthAccessState = .requested
                runningTotalsError = "No readable runs. Check Health access in Settings."
                return
            }
            healthAccessState = .workoutsAvailable
            let summaries = workouts.map {
                RunSummary(
                    startDate: $0.startDate,
                    distanceMetres: $0.totalDistance?.doubleValue(for: .meter()) ?? 0
                )
            }
            runningTotals = RunningTotals.aggregate(
                runs: summaries,
                now: Date(),
                calendar: .current
            )
        } catch {
            healthAccessState = .unavailable
            runningTotalsError = error.localizedDescription
        }
    }

    func load() async {
        guard loadState == .idle else { return }
        let generation = loadGeneration.begin()
        loadState = .loading
        healthAccessState = .checking
        do {
            try await healthKitManager.requestAuthorization()
            guard loadGeneration.isCurrent(generation) else { return }
            healthAccessState = .requested
            let runs = try await healthKitManager.fetchRecentRuns()
            guard loadGeneration.isCurrent(generation) else { return }
            recentRuns = runs
            healthAccessState = runs.isEmpty ? .requested : .workoutsAvailable
            guard let first = recentRuns.first else {
                loadState = .empty(
                    title: "No Readable Runs",
                    message: "No readable running workouts were found. Check Health access or record a run first."
                )
                return
            }

            var selection = InitialRouteSelection(candidateCount: recentRuns.count)
            var firstError: Error?
            while let candidateIndex = selection.currentCandidateIndex {
                let workout = recentRuns[candidateIndex]
                do {
                    let route = try await fetchRouteDataCancellingPrevious(for: workout)
                    guard loadGeneration.isCurrent(generation) else { return }
                    guard selection.recordCurrent(hasRoute: true) == candidateIndex else { continue }
                    present(route: route, for: workout)
                    return
                } catch HealthKitManagerError.noRoute {
                    guard loadGeneration.isCurrent(generation) else { return }
                    _ = selection.recordCurrent(hasRoute: false)
                } catch {
                    guard loadGeneration.isCurrent(generation) else { return }
                    if firstError == nil { firstError = error }
                    _ = selection.recordCurrent(hasRoute: false)
                }
            }

            guard loadGeneration.isCurrent(generation) else { return }
            selectedWorkout = first
            if let firstError {
                loadState = .failed(firstError.localizedDescription)
            } else {
                loadState = .empty(
                    title: "No Route",
                    message: HealthKitManagerError.noRoute.localizedDescription
                )
            }
        } catch {
            guard loadGeneration.isCurrent(generation) else { return }
            healthAccessState = .unavailable
            loadState = .failed(error.localizedDescription)
        }
    }

    func selectWorkout(_ workout: HKWorkout) async {
        let generation = loadGeneration.begin()
        stopPlayback()
        selectedWorkout = workout
        routeCoordinates = []
        routeCoordinateParts = []
        routePath = RoutePath(points: [])
        routeTimestamps = nil
        completedSplitCache = CompletedSplitCache(cumulativeDistances: [], timestamps: nil)
        ghostCoordinate = nil
        elevationGainMetres = nil
        playbackDistance = 0
        selectedSplitIndex = nil
        loadState = .loading

        do {
            let route = try await fetchRouteDataCancellingPrevious(for: workout)
            guard loadGeneration.isCurrent(generation) else { return }
            present(route: route, for: workout)
        } catch HealthKitManagerError.noRoute {
            guard loadGeneration.isCurrent(generation) else { return }
            loadState = .empty(
                title: "No Route",
                message: HealthKitManagerError.noRoute.localizedDescription
            )
        } catch {
            guard loadGeneration.isCurrent(generation) else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    func selectWorkout(id: UUID) async {
        guard let workout = recentRuns.first(where: { $0.uuid == id }) else { return }
        await selectWorkout(workout)
    }

    func retry() async {
        _ = loadGeneration.begin()
        routeLoadTask?.cancel()
        stopPlayback()
        recentRuns = []
        selectedWorkout = nil
        routeCoordinates = []
        routeCoordinateParts = []
        routePath = RoutePath(points: [])
        routeTimestamps = nil
        completedSplitCache = CompletedSplitCache(cumulativeDistances: [], timestamps: nil)
        ghostCoordinate = nil
        elevationGainMetres = nil
        playbackDistance = 0
        selectedSplitIndex = nil
        loadState = .idle
        await load()
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func selectSplit(_ split: ObservedSplit) {
        stopPlayback()
        selectedSplitIndex = split.index
        playbackDistance = min(max(0, split.startDistance), routePath.totalDistance)
        updateGhostCoordinate()
    }

    func scrub(to value: Double) {
        let maximum = maximumScrubberValue
        let progress = min(max(0, value.isFinite ? value : 0), maximum)
        playbackDistance = routePath.distance(atProgress: progress)
        let nearestIndex = Int(progress.rounded())
        if abs(progress - Double(nearestIndex)) < 0.000_001,
           let point = routePath.point(atIndex: nearestIndex) {
            ghostCoordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            return
        }
        updateGhostCoordinate()
    }

    private func startPlayback() {
        let duration = selectedWorkout?.duration ?? 0
        guard routePath.isPlayable,
              PlaybackMath.canStart(routeDistance: routePath.totalDistance, workoutDuration: duration) else { return }
        if playbackDistance >= routePath.totalDistance {
            scrub(to: 0)
        }

        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var previous = clock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying else { return }
                let now = clock.now
                let elapsed = previous.duration(to: now).seconds
                previous = now

                let priorDistance = self.playbackDistance
                self.playbackDistance = PlaybackMath.advancedDistance(
                    from: self.playbackDistance,
                    elapsed: elapsed,
                    speed: self.playbackSpeed,
                    routeDistance: self.routePath.totalDistance,
                    workoutDuration: duration
                )
                guard self.playbackDistance > priorDistance else {
                    self.stopPlayback()
                    return
                }
                self.updateGhostCoordinate()

                if self.playbackDistance >= self.routePath.totalDistance {
                    self.stopPlayback()
                }
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func updateGhostCoordinate() {
        guard let point = routePath.point(atDistance: playbackDistance) else {
            ghostCoordinate = nil
            return
        }
        ghostCoordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private func present(route: WorkoutRouteData, for workout: HKWorkout) {
        selectedWorkout = workout
        routeCoordinates = route.coordinates
        routeCoordinateParts = route.coordinateParts
        routePath = route.path
        routeTimestamps = route.timestamps
        completedSplitCache = CompletedSplitCache(
            cumulativeDistances: route.path.cumulativeDistances,
            timestamps: route.timestamps,
            segmentStartIndices: route.path.segmentStartIndices,
            segmentStartDistances: route.path.segmentStartDistances
        )
        ghostCoordinate = route.coordinates.first
        elevationGainMetres = route.elevationGainMetres
        playbackDistance = 0
        selectedSplitIndex = nil
        playbackSpeed = defaultPlaybackSpeed
        routePresentationID = routePresentationGeneration.begin()
        loadState = .ready
    }

    private func fetchRouteDataCancellingPrevious(for workout: HKWorkout) async throws -> WorkoutRouteData {
        routeLoadTask?.cancel()
        routeLoadToken &+= 1
        let token = routeLoadToken
        let task = Task { try await healthKitManager.fetchRouteData(for: workout) }
        routeLoadTask = task
        defer {
            if routeLoadToken == token { routeLoadTask = nil }
        }
        return try await task.value
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
