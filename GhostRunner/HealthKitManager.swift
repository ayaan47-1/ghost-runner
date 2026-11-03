@preconcurrency import HealthKit
import CoreLocation
import Foundation

struct WorkoutRouteData: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let elevationGainMetres: Double?
    let path: RoutePath
    let timestamps: [TimeInterval]?
}

private final class RouteQueryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [TimedRoutePoint] = []
    private var isFinished = false

    func receive(
        batch: [TimedRoutePoint],
        done: Bool,
        error: Error?,
        continuation: CheckedContinuation<[TimedRoutePoint], Error>
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        if let error {
            isFinished = true
            lock.unlock()
            continuation.resume(throwing: error)
            return
        }

        samples.append(contentsOf: batch)
        guard done else {
            lock.unlock()
            return
        }

        isFinished = true
        let result = samples
        lock.unlock()
        continuation.resume(returning: result)
    }
}

enum HealthKitManagerError: LocalizedError {
    case healthDataUnavailable
    case noRoute

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is unavailable or restricted on this device."
        case .noRoute:
            return "This workout has no outdoor GPS route. Indoor and treadmill runs usually do not include one. Also check Settings > Health > Ghost Runner > Workout Routes is on."
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: [workout, route, heartRate]) { success, error in
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

    func fetchRecentRuns(limit: Int = 10) async throws -> [HKWorkout] {
        let safeLimit = max(1, limit)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let predicate = HKQuery.predicateForWorkouts(with: .running)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: safeLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
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

        var parts: [[TimedRoutePoint]] = []
        for route in routes {
            parts.append(try await fetchLocations(for: route))
        }

        let result = await Task.detached(priority: .userInitiated) { () -> WorkoutRouteData? in
            let samples = RouteMath.mergedChronologically(parts: parts)
            guard !samples.isEmpty else { return nil }
            let path = RoutePath(points: samples.map(\.point))
            return WorkoutRouteData(
                coordinates: path.points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                },
                elevationGainMetres: Self.elevationGain(from: samples),
                path: path,
                timestamps: samples.allSatisfy({ $0.timestamp.isFinite })
                    ? samples.map(\.timestamp)
                    : nil
            )
        }.value
        guard let result else {
            throw HealthKitManagerError.noRoute
        }
        return result
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkoutRoute], Error>) in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [TimedRoutePoint] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TimedRoutePoint], Error>) in
            let accumulator = RouteQueryAccumulator()
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                let batch = (locations ?? []).map {
                    TimedRoutePoint(
                        point: GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude),
                        altitude: $0.altitude,
                        hasReliableAltitude: $0.verticalAccuracy >= 0,
                        timestamp: $0.timestamp.timeIntervalSinceReferenceDate
                    )
                }
                accumulator.receive(
                    batch: batch,
                    done: done,
                    error: error,
                    continuation: continuation
                )
            }
            healthStore.execute(query)
        }
    }

    nonisolated private static func elevationGain(from locations: [TimedRoutePoint]) -> Double? {
        let reliable = locations.filter(\.hasReliableAltitude)
        guard reliable.count > 1 else { return nil }

        return zip(reliable, reliable.dropFirst()).reduce(0) { gain, pair in
            gain + max(0, pair.1.altitude - pair.0.altitude)
        }
    }
}
