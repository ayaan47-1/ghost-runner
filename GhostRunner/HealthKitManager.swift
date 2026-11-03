@preconcurrency import HealthKit
import CoreLocation
import Foundation

struct WorkoutRouteData: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let elevationGainMetres: Double?
}

private struct RouteLocationSample: Sendable {
    let coordinate: CLLocationCoordinate2D
    let altitude: Double
    let hasReliableAltitude: Bool
}

enum HealthKitManagerError: LocalizedError {
    case healthDataUnavailable
    case noRoute

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is unavailable or restricted on this device."
        case .noRoute:
            return "This workout has no outdoor GPS route. Indoor and treadmill runs usually do not include one."
        }
    }
}

@MainActor
final class HealthKitManager {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitManagerError.healthDataUnavailable
        }

        let workout = HKWorkoutType.workoutType()
        let route = HKSeriesType.workoutRoute()
        guard let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitManagerError.healthDataUnavailable
        }

        try await withCheckedThrowingContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [workout, route, heartRate]) { success, error in
                Task { @MainActor in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HealthKitManagerError.healthDataUnavailable)
                    }
                }
            }
        }
    }

    func fetchRecentRuns(limit: Int = 10) async throws -> [HKWorkout] {
        let safeLimit = max(1, limit)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForWorkouts(with: .running)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: safeLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                Task { @MainActor in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                    }
                }
            }
            healthStore.execute(query)
        }
    }

    func fetchRouteCoordinates(for workout: HKWorkout) async throws -> [CLLocationCoordinate2D] {
        try await fetchRouteData(for: workout).coordinates
    }

    func fetchRouteData(for workout: HKWorkout) async throws -> WorkoutRouteData {
        let routes = try await fetchRoutes(for: workout)
        guard !routes.isEmpty else { throw HealthKitManagerError.noRoute }

        var samples: [RouteLocationSample] = []
        for route in routes {
            samples.append(contentsOf: try await fetchLocations(for: route))
        }
        guard !samples.isEmpty else { throw HealthKitManagerError.noRoute }

        return await Task.detached(priority: .userInitiated) {
            WorkoutRouteData(
                coordinates: samples.map(\.coordinate),
                elevationGainMetres: Self.elevationGain(from: samples)
            )
        }.value
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                Task { @MainActor in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
                    }
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [RouteLocationSample] {
        try await withCheckedThrowingContinuation { continuation in
            var allSamples: [RouteLocationSample] = []
            var isFinished = false
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                let batch = (locations ?? []).map {
                    RouteLocationSample(
                        coordinate: $0.coordinate,
                        altitude: $0.altitude,
                        hasReliableAltitude: $0.verticalAccuracy >= 0
                    )
                }
                Task { @MainActor in
                    guard !isFinished else { return }
                    if let error {
                        isFinished = true
                        continuation.resume(throwing: error)
                        return
                    }
                    allSamples.append(contentsOf: batch)
                    if done {
                        isFinished = true
                        continuation.resume(returning: allSamples)
                    }
                }
            }
            healthStore.execute(query)
        }
    }

    nonisolated private static func elevationGain(from locations: [RouteLocationSample]) -> Double? {
        let reliable = locations.filter(\.hasReliableAltitude)
        guard reliable.count > 1 else { return nil }

        return zip(reliable, reliable.dropFirst()).reduce(0) { gain, pair in
            gain + max(0, pair.1.altitude - pair.0.altitude)
        }
    }
}
