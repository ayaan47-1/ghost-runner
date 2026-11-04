@preconcurrency import HealthKit
import CoreLocation
import Foundation

struct WorkoutRouteData: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let coordinateParts: [[CLLocationCoordinate2D]]
    let elevationGainMetres: Double?
    let path: RoutePath
    let timestamps: [TimeInterval]?
}

private final class RouteQueryAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let healthStore: HKHealthStore
    private var samples: [TimedRoutePoint] = []
    private var continuation: CheckedContinuation<[TimedRoutePoint], Error>?
    private var query: HKWorkoutRouteQuery?
    private var gate = QueryCancellationGate()

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    func install(_ continuation: CheckedContinuation<[TimedRoutePoint], Error>) {
        lock.lock()
        guard gate.canProject else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func start(_ query: HKWorkoutRouteQuery) {
        lock.lock()
        guard gate.canProject else {
            lock.unlock()
            return
        }
        self.query = query
        healthStore.execute(query)
        lock.unlock()
    }

    func receive(
        batch: [TimedRoutePoint],
        done: Bool,
        error: Error?,
        continuation _: CheckedContinuation<[TimedRoutePoint], Error>? = nil
    ) {
        lock.lock()
        guard gate.canProject else {
            lock.unlock()
            return
        }

        if let error {
            guard gate.finish() else { lock.unlock(); return }
            let continuation = self.continuation
            self.continuation = nil
            query = nil
            lock.unlock()
            continuation?.resume(throwing: error)
            return
        }

        samples.append(contentsOf: batch)
        guard done else {
            lock.unlock()
            return
        }

        guard gate.finish() else { lock.unlock(); return }
        let result = samples
        let continuation = self.continuation
        self.continuation = nil
        query = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func cancel() {
        lock.lock()
        guard gate.cancel() else { lock.unlock(); return }
        let query = self.query
        self.query = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let query { healthStore.stop(query) }
        continuation?.resume(throwing: CancellationError())
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: [workout, route]) { success, error in
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
        try await fetchRuns(limit: max(1, limit))
    }

    func fetchAllRuns() async throws -> [HKWorkout] {
        try await fetchRuns(limit: HKObjectQueryNoLimit)
    }

    private func fetchRuns(limit: Int) async throws -> [HKWorkout] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let predicate = HKQuery.predicateForWorkouts(with: .running)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: limit,
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

        try Task.checkCancellation()
        let result = await withTaskGroup(of: WorkoutRouteData?.self) { group in
            group.addTask(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                let orderedParts = RouteMath.orderedPartsChronologically(parts: parts)
                guard !Task.isCancelled else { return nil }
                let samples = orderedParts.flatMap { $0 }
                let path = RoutePath(parts: orderedParts.map { $0.map(\.point) })
                guard !Task.isCancelled, path.isPlayable else { return nil }
                let coordinateParts = path.parts.map { part in
                    part.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                }
                return WorkoutRouteData(
                    coordinates: coordinateParts.flatMap { $0 },
                    coordinateParts: coordinateParts,
                    elevationGainMetres: ElevationMath.gain(parts: orderedParts),
                    path: path,
                    timestamps: samples.allSatisfy({ $0.timestamp.isFinite })
                        ? samples.map(\.timestamp)
                        : nil
                )
            }
            return await group.next() ?? nil
        }
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
        let accumulator = RouteQueryAccumulator(healthStore: healthStore)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TimedRoutePoint], Error>) in
                accumulator.install(continuation)
                let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    let batch = (locations ?? []).map {
                        TimedRoutePoint(
                            point: GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude),
                            altitude: $0.altitude,
                            verticalAccuracy: $0.verticalAccuracy,
                            timestamp: $0.timestamp.timeIntervalSinceReferenceDate
                        )
                    }
                    accumulator.receive(batch: batch, done: done, error: error)
                }
                accumulator.start(query)
            }
        } onCancel: {
            accumulator.cancel()
        }
    }
}
