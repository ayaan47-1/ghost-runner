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
    private(set) var importedRuns: [ImportedRun] = []
    private(set) var selectedWorkout: HKWorkout?
    private(set) var selectedRun: ReplayRunSummary?
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
    var importErrorMessage: String?

    private let healthKitManager: HealthKitManager
    private let importedRunStore: ImportedRunStore
    private var playbackTask: Task<Void, Never>?
    private var routeLoadTask: Task<WorkoutRouteData, Error>?
    private var routeLoadToken: UInt64 = 0
    private var playbackPosition = RoutePlaybackPosition()
    private var playbackDistance: Double {
        get { playbackPosition.distance }
        set { playbackPosition.move(toDistance: newValue, in: routePath) }
    }
    private var routePath = RoutePath(points: [])
    private var routeTimestamps: [TimeInterval]?
    private var completedSplitCache = CompletedSplitCache(cumulativeDistances: [], timestamps: nil)
    private var loadGeneration = LoadGeneration()
    private var routePresentationGeneration = LoadGeneration()

    init(
        healthKitManager: HealthKitManager = HealthKitManager(),
        importedRunStore: ImportedRunStore = ImportedRunStore(
            directoryURL: ImportedRunStore.defaultDirectoryURL
        )
    ) {
        self.healthKitManager = healthKitManager
        self.importedRunStore = importedRunStore
    }

    var runs: [ReplayRunSummary] {
        let healthRuns = recentRuns.map { workout in
            ReplayRunSummary(
                id: workout.uuid,
                name: nil,
                startDate: workout.startDate,
                duration: workout.duration,
                distanceMetres: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                source: .health
            )
        }
        return (healthRuns + importedRuns.map(\.summary)).sorted { $0.startDate > $1.startDate }
    }

    var scrubberValue: Double {
        get { playbackPosition.scrubberValue(in: routePath) }
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
            metres: selectedRun?.distanceMetres ?? 0,
            units: unitPreference
        )
    }

    var formattedDuration: String {
        RunFormatting.duration(seconds: selectedRun?.duration ?? 0)
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
        guard let run = selectedRun, run.distanceMetres > 0 else {
            return nil
        }
        return run.duration / (run.distanceMetres / 1_000)
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
        await reloadImportedRuns()
        do {
            try await healthKitManager.requestAuthorization()
            guard loadGeneration.isCurrent(generation) else { return }
            healthAccessState = .requested
            let runs = try await healthKitManager.fetchRecentRuns()
            guard loadGeneration.isCurrent(generation) else { return }
            recentRuns = runs
            healthAccessState = runs.isEmpty ? .requested : .workoutsAvailable
            guard let first = recentRuns.first else {
                if let imported = importedRuns.first {
                    present(importedRun: imported)
                    return
                }
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
            if let imported = importedRuns.first {
                present(importedRun: imported)
                return
            }
            selectedWorkout = first
            selectedRun = summary(for: first)
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
            if let imported = importedRuns.first {
                present(importedRun: imported)
                return
            }
            loadState = .failed(error.localizedDescription)
        }
    }

    func selectWorkout(_ workout: HKWorkout) async {
        let generation = loadGeneration.begin()
        stopPlayback()
        selectedWorkout = workout
        selectedRun = summary(for: workout)
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
        if let imported = importedRuns.first(where: { $0.id == id }) {
            let generation = loadGeneration.begin()
            routeLoadTask?.cancel()
            stopPlayback()
            guard loadGeneration.isCurrent(generation) else { return }
            present(importedRun: imported)
        } else if let workout = recentRuns.first(where: { $0.uuid == id }) {
            await selectWorkout(workout)
        }
    }

    @discardableResult
    func importGPX(from url: URL) async -> Bool {
        do {
            let run = try await importedRunStore.importGPX(from: url)
            await reloadImportedRuns()
            _ = loadGeneration.begin()
            routeLoadTask?.cancel()
            stopPlayback()
            present(importedRun: run)
            importErrorMessage = nil
            return true
        } catch {
            importErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteImportedRun(id: UUID) async {
        do {
            try await importedRunStore.delete(id: id)
            await reloadImportedRuns()
            if selectedRun?.id == id {
                stopPlayback()
                selectedRun = nil
                selectedWorkout = nil
                resetRoute()
                if let next = runs.first {
                    await selectWorkout(id: next.id)
                } else {
                    loadState = .empty(
                        title: "No Runs Found",
                        message: "Import a GPX file or allow Health access."
                    )
                }
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    func retry() async {
        _ = loadGeneration.begin()
        routeLoadTask?.cancel()
        stopPlayback()
        recentRuns = []
        selectedWorkout = nil
        selectedRun = nil
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
        playbackPosition.scrub(to: progress, in: routePath)
        let nearestIndex = Int(progress.rounded())
        if abs(progress - Double(nearestIndex)) < 0.000_001,
           let point = routePath.point(atIndex: nearestIndex) {
            ghostCoordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            return
        }
        updateGhostCoordinate()
    }

    private func startPlayback() {
        let duration = selectedRun?.duration ?? 0
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
        selectedRun = summary(for: workout)
        present(route: route)
    }

    private func present(importedRun: ImportedRun) {
        let timeline = importedRun.routeTimeline
        guard timeline.path.isPlayable, importedRun.duration > 0 else {
            selectedWorkout = nil
            selectedRun = importedRun.summary
            resetRoute()
            loadState = .empty(
                title: "No Replayable Route",
                message: "This GPX file does not contain enough timed movement to replay."
            )
            return
        }
        let parts = timeline.parts.map { part in
            part.map { point in
                CLLocationCoordinate2D(
                    latitude: point.point.latitude,
                    longitude: point.point.longitude
                )
            }
        }
        selectedWorkout = nil
        selectedRun = importedRun.summary
        present(route: WorkoutRouteData(
            coordinates: timeline.samples.map { point in
                CLLocationCoordinate2D(
                    latitude: point.point.latitude,
                    longitude: point.point.longitude
                )
            },
            coordinateParts: parts,
            elevationGainMetres: ElevationMath.gain(parts: timeline.parts),
            path: timeline.path,
            timestamps: timeline.timestamps
        ))
    }

    private func present(route: WorkoutRouteData) {
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

    private func reloadImportedRuns() async {
        do {
            importedRuns = try await importedRunStore.load()
        } catch {
            importErrorMessage = "Saved GPX runs could not be loaded: \(error.localizedDescription)"
        }
    }

    private func summary(for workout: HKWorkout) -> ReplayRunSummary {
        ReplayRunSummary(
            id: workout.uuid,
            name: nil,
            startDate: workout.startDate,
            duration: workout.duration,
            distanceMetres: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
            source: .health
        )
    }

    private func resetRoute() {
        routeCoordinates = []
        routeCoordinateParts = []
        routePath = RoutePath(points: [])
        routeTimestamps = nil
        completedSplitCache = CompletedSplitCache(cumulativeDistances: [], timestamps: nil)
        ghostCoordinate = nil
        elevationGainMetres = nil
        playbackDistance = 0
        selectedSplitIndex = nil
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
