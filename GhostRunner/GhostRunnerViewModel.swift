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
    var isWorkoutPickerPresented = false

    private let healthKitManager: HealthKitManager
    private var playbackTask: Task<Void, Never>?
    private var playbackDistance = 0.0
    private var routePath = RoutePath(points: [])
    private var selectionGeneration = SelectionGeneration()

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
        Locale.current.measurementSystem == .metric ? .metric : .imperial
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
        guard let workout = selectedWorkout,
              let metres = workout.totalDistance?.doubleValue(for: .meter()),
              metres > 0 else {
            return "—"
        }
        return RunFormatting.pace(
            secondsPerKilometre: workout.duration / (metres / 1_000),
            units: unitPreference
        )
    }

    var formattedElevationGain: String {
        RunFormatting.elevationGain(metres: elevationGainMetres, units: unitPreference)
    }

    func load() async {
        guard loadState == .idle else { return }
        loadState = .loading
        do {
            try await healthKitManager.requestAuthorization()
            recentRuns = try await healthKitManager.fetchRecentRuns()
            guard let first = recentRuns.first else {
                loadState = .empty(
                    title: "No Readable Runs",
                    message: "No readable running workouts were found. Check Health access or record a run first."
                )
                return
            }
            await selectWorkout(first)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func selectWorkout(_ workout: HKWorkout) async {
        let generation = selectionGeneration.begin()
        stopPlayback()
        selectedWorkout = workout
        routeCoordinates = []
        routePath = RoutePath(points: [])
        ghostCoordinate = nil
        elevationGainMetres = nil
        ghostCoordinateIndex = 0
        playbackDistance = 0
        loadState = .loading

        do {
            let route = try await healthKitManager.fetchRouteData(for: workout)
            guard selectionGeneration.isCurrent(generation) else { return }
            routeCoordinates = route.coordinates
            routePath = route.path
            ghostCoordinate = route.coordinates.first
            elevationGainMetres = route.elevationGainMetres
            loadState = .ready
            isWorkoutPickerPresented = false
        } catch HealthKitManagerError.noRoute {
            guard selectionGeneration.isCurrent(generation) else { return }
            loadState = .empty(
                title: "No Route",
                message: HealthKitManagerError.noRoute.localizedDescription
            )
        } catch {
            guard selectionGeneration.isCurrent(generation) else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    func selectWorkout(id: UUID) async {
        guard let workout = recentRuns.first(where: { $0.uuid == id }) else { return }
        await selectWorkout(workout)
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
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
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
