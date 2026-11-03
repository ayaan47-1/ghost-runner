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
        case empty(String)
        case failed(String)
    }

    let playbackSpeeds = [1.0, 2.0, 5.0, 10.0]

    private(set) var recentRuns: [HKWorkout] = []
    var selectedWorkout: HKWorkout?
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var elevationGainMetres: Double?
    var ghostCoordinateIndex = 0
    private(set) var isPlaying = false
    var playbackSpeed = 1.0
    var loadState: LoadState = .idle
    var isWorkoutPickerPresented = false

    private let healthKitManager: HealthKitManager
    private var playbackTask: Task<Void, Never>?
    private var playbackPosition = 0.0

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
                loadState = .empty("No readable running workouts were found. Check Health access or record a run first.")
                return
            }
            await selectWorkout(first)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func selectWorkout(_ workout: HKWorkout) async {
        stopPlayback()
        selectedWorkout = workout
        routeCoordinates = []
        elevationGainMetres = nil
        ghostCoordinateIndex = 0
        playbackPosition = 0
        loadState = .loading

        do {
            let route = try await healthKitManager.fetchRouteData(for: workout)
            routeCoordinates = route.coordinates
            elevationGainMetres = route.elevationGainMetres
            loadState = .ready
            isWorkoutPickerPresented = false
        } catch HealthKitManagerError.noRoute {
            loadState = .empty(HealthKitManagerError.noRoute.localizedDescription)
        } catch {
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
        playbackPosition = Double(index)
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

                let duration = max(1, self.selectedWorkout?.duration ?? 1)
                let pointsPerSecond = Double(self.routeCoordinates.count - 1) / duration
                self.playbackPosition += elapsed * self.playbackSpeed * pointsPerSecond
                self.ghostCoordinateIndex = PlaybackMath.scrubbedIndex(
                    for: self.playbackPosition,
                    routeCount: self.routeCoordinates.count
                )

                if self.ghostCoordinateIndex >= self.routeCoordinates.count - 1 {
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
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
