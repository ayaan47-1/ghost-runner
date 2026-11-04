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
    private(set) var ghostCoordinate: CLLocationCoordinate2D?
    private(set) var elevationGainMetres: Double?
    var ghostCoordinateIndex = 0
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
    private var playbackDistance = 0.0
    private var routePath = RoutePath(points: [])
    private var routeTimestamps: [TimeInterval]?
    private var loadGeneration = LoadGeneration()
    private var routePresentationGeneration = LoadGeneration()

    init(healthKitManager: HealthKitManager = HealthKitManager()) {
        self.healthKitManager = healthKitManager
    }

    var scrubberValue: Double {
        get { Double(ghostCoordinateIndex) }
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
        SplitMath.completed(
            cumulativeDistances: routePath.cumulativeDistances,
            timestamps: routeTimestamps,
            units: unitPreference
        )
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
            healthAccessState = workouts.isEmpty ? .requested : .workoutsAvailable
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
                    let route = try await healthKitManager.fetchRouteData(for: workout)
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
        routePath = RoutePath(points: [])
        routeTimestamps = nil
        ghostCoordinate = nil
        elevationGainMetres = nil
        ghostCoordinateIndex = 0
        playbackDistance = 0
        selectedSplitIndex = nil
        loadState = .loading

        do {
            let route = try await healthKitManager.fetchRouteData(for: workout)
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
        stopPlayback()
        recentRuns = []
        selectedWorkout = nil
        routeCoordinates = []
        routePath = RoutePath(points: [])
        routeTimestamps = nil
        ghostCoordinate = nil
        elevationGainMetres = nil
        ghostCoordinateIndex = 0
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
        ghostCoordinateIndex = routePath.index(atDistance: playbackDistance)
        updateGhostCoordinate()
    }

    func scrub(to value: Double) {
        let index = PlaybackMath.scrubbedIndex(for: value, routeCount: routeCoordinates.count)
        ghostCoordinateIndex = index
        playbackDistance = routePath.distance(at: index)
        updateGhostCoordinate()
    }

    private func startPlayback() {
        guard routeCoordinates.count > 1 else { return }
        if ghostCoordinateIndex >= routeCoordinates.count - 1 {
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

                self.playbackDistance = PlaybackMath.advancedDistance(
                    from: self.playbackDistance,
                    elapsed: elapsed,
                    speed: self.playbackSpeed,
                    routeDistance: self.routePath.totalDistance,
                    workoutDuration: self.selectedWorkout?.duration ?? 0
                )
                self.ghostCoordinateIndex = self.routePath.index(atDistance: self.playbackDistance)
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
        routePath = route.path
        routeTimestamps = route.timestamps
        ghostCoordinate = route.coordinates.first
        elevationGainMetres = route.elevationGainMetres
        ghostCoordinateIndex = 0
        playbackDistance = 0
        selectedSplitIndex = nil
        playbackSpeed = defaultPlaybackSpeed
        routePresentationID = routePresentationGeneration.begin()
        loadState = .ready
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
