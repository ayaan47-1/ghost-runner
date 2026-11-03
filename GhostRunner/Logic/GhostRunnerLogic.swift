import Foundation

public struct GeoPoint: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct RouteRegion: Equatable, Sendable {
    public let center: GeoPoint
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(center: GeoPoint, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

public struct TimedRoutePoint: Equatable, Sendable {
    public let point: GeoPoint
    public let altitude: Double
    public let hasReliableAltitude: Bool
    public let timestamp: TimeInterval

    public init(
        point: GeoPoint,
        altitude: Double = 0,
        hasReliableAltitude: Bool = false,
        timestamp: TimeInterval
    ) {
        self.point = point
        self.altitude = altitude
        self.hasReliableAltitude = hasReliableAltitude
        self.timestamp = timestamp
    }
}

public struct RoutePath: Sendable {
    public let points: [GeoPoint]
    public let cumulativeDistances: [Double]

    public init(points: [GeoPoint]) {
        self.points = points
        guard !points.isEmpty else {
            cumulativeDistances = []
            return
        }

        var distances = [0.0]
        distances.reserveCapacity(points.count)
        for pair in zip(points, points.dropFirst()) {
            distances.append(distances[distances.count - 1] + RouteMath.distance(from: pair.0, to: pair.1))
        }
        cumulativeDistances = distances
    }

    public var totalDistance: Double {
        cumulativeDistances.last ?? 0
    }

    public func distance(at index: Int) -> Double {
        guard !cumulativeDistances.isEmpty else { return 0 }
        return cumulativeDistances[min(max(0, index), cumulativeDistances.count - 1)]
    }

    public func index(atDistance distance: Double) -> Int {
        guard !cumulativeDistances.isEmpty else { return 0 }
        let target = min(max(0, distance.isFinite ? distance : 0), totalDistance)
        let upperIndex = cumulativeDistances.partitioningIndex { $0 >= target }
        guard upperIndex > 0, upperIndex < cumulativeDistances.count else {
            return min(upperIndex, cumulativeDistances.count - 1)
        }
        let lowerIndex = upperIndex - 1
        return target - cumulativeDistances[lowerIndex]
            <= cumulativeDistances[upperIndex] - target ? lowerIndex : upperIndex
    }

    public func point(atDistance distance: Double) -> GeoPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1, totalDistance > 0 else { return first }

        let target = min(max(0, distance.isFinite ? distance : 0), totalDistance)
        guard target > 0 else { return first }
        guard target < totalDistance else { return points.last }

        let upperIndex = cumulativeDistances.partitioningIndex { $0 >= target }
        let lowerIndex = max(0, upperIndex - 1)
        let segmentLength = cumulativeDistances[upperIndex] - cumulativeDistances[lowerIndex]
        guard segmentLength > 0 else { return points[upperIndex] }

        let progress = (target - cumulativeDistances[lowerIndex]) / segmentLength
        let start = points[lowerIndex]
        let end = points[upperIndex]
        let longitudeDelta = RouteMath.shortestLongitudeDelta(from: start.longitude, to: end.longitude)
        return GeoPoint(
            latitude: start.latitude + (end.latitude - start.latitude) * progress,
            longitude: RouteMath.normalizedLongitude(start.longitude + longitudeDelta * progress)
        )
    }
}

public enum RouteMath {
    private static let earthRadiusMetres = 6_371_000.0

    public static func fittedRegion(
        for points: [GeoPoint],
        paddingFactor: Double = 1.25,
        minimumSpan: Double = 0.002
    ) -> RouteRegion? {
        guard let first = points.first else { return nil }

        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude

        for point in points.dropFirst() {
            minimumLatitude = min(minimumLatitude, point.latitude)
            maximumLatitude = max(maximumLatitude, point.latitude)
        }

        let longitudeFit = shortestLongitudeInterval(points.map(\.longitude))

        let safePadding = max(1, paddingFactor)
        let safeMinimumSpan = max(0.000_001, minimumSpan)
        let latitudeDelta = min(180, max(safeMinimumSpan, (maximumLatitude - minimumLatitude) * safePadding))
        let longitudeDelta = min(360, max(safeMinimumSpan, longitudeFit.span * safePadding))

        return RouteRegion(
            center: GeoPoint(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: longitudeFit.center
            ),
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    public static func mergedChronologically(parts: [[TimedRoutePoint]]) -> [TimedRoutePoint] {
        parts.flatMap { $0 }.enumerated().sorted { left, right in
            if left.element.timestamp == right.element.timestamp {
                return left.offset < right.offset
            }
            return left.element.timestamp < right.element.timestamp
        }.map(\.element)
    }

    public static func distance(from start: GeoPoint, to end: GeoPoint) -> Double {
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
        let longitudeDelta = shortestLongitudeDelta(from: start.longitude, to: end.longitude) * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadiusMetres * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    static func shortestLongitudeDelta(from start: Double, to end: Double) -> Double {
        normalizedLongitude(end - start)
    }

    static func normalizedLongitude(_ longitude: Double) -> Double {
        let normalized = (longitude + 180).truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return positive - 180
    }

    private static func shortestLongitudeInterval(_ longitudes: [Double]) -> (center: Double, span: Double) {
        guard let first = longitudes.first else { return (0, 0) }
        guard longitudes.count > 1 else {
            return ((-180...180).contains(first) ? first : normalizedLongitude(first), 0)
        }

        let sorted = longitudes.map { longitude -> Double in
            let normalized = normalizedLongitude(longitude)
            return normalized < 0 ? normalized + 360 : normalized
        }.sorted()

        var largestGap = -Double.infinity
        var intervalStart = sorted[0]
        for index in sorted.indices {
            let nextIndex = (index + 1) % sorted.count
            let next = nextIndex == 0 ? sorted[0] + 360 : sorted[nextIndex]
            let gap = next - sorted[index]
            if gap > largestGap {
                largestGap = gap
                intervalStart = next.truncatingRemainder(dividingBy: 360)
            }
        }

        let span = max(0, 360 - largestGap)
        return (normalizedLongitude(intervalStart + span / 2), span)
    }
}

public enum PlaybackMath {
    public static func advancedDistance(
        from currentDistance: Double,
        elapsed: TimeInterval,
        speed: Double,
        routeDistance: Double,
        workoutDuration: TimeInterval
    ) -> Double {
        let safeRouteDistance = routeDistance.isFinite ? max(0, routeDistance) : 0
        let safeCurrent = currentDistance.isFinite ? min(max(0, currentDistance), safeRouteDistance) : 0
        guard elapsed.isFinite, speed.isFinite, workoutDuration.isFinite,
              elapsed > 0, speed > 0, workoutDuration > 0, safeRouteDistance > 0 else {
            return safeCurrent
        }
        let metresPerSecond = safeRouteDistance / workoutDuration
        return min(safeRouteDistance, safeCurrent + elapsed * speed * metresPerSecond)
    }

    public static func advancedIndex(
        from currentIndex: Int,
        elapsed: TimeInterval,
        speed: Double,
        pointsPerSecond: Double,
        routeCount: Int
    ) -> Int {
        guard routeCount > 0 else { return 0 }

        let lastIndex = routeCount - 1
        let clampedCurrent = min(max(0, currentIndex), lastIndex)
        guard elapsed.isFinite, speed.isFinite, pointsPerSecond.isFinite,
              elapsed > 0, speed > 0, pointsPerSecond > 0 else {
            return clampedCurrent
        }

        let advancedPoints = Int((elapsed * speed * pointsPerSecond).rounded(.down))
        return min(lastIndex, clampedCurrent + advancedPoints)
    }

    public static func scrubbedIndex(for value: Double, routeCount: Int) -> Int {
        guard routeCount > 0, value.isFinite else { return 0 }
        return min(routeCount - 1, max(0, Int(value.rounded())))
    }
}

public struct SelectionGeneration: Sendable {
    private var value: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        value &+= 1
        return value
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

private extension Collection where Element == Double, Index == Int {
    func partitioningIndex(where predicate: (Double) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

public enum UnitPreference: Sendable {
    case metric
    case imperial
}

public enum RunFormatting {
    private static let metresPerMile = 1_609.344
    private static let feetPerMetre = 3.280_84
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public static func distance(metres: Double, units: UnitPreference) -> String {
        let safeMetres = metres.isFinite ? max(0, metres) : 0
        switch units {
        case .metric:
            return String(format: "%.2f km", locale: posixLocale, safeMetres / 1_000)
        case .imperial:
            return String(format: "%.2f mi", locale: posixLocale, safeMetres / metresPerMile)
        }
    }

    public static func pace(secondsPerKilometre: Double?, units: UnitPreference) -> String {
        guard let secondsPerKilometre,
              secondsPerKilometre.isFinite,
              secondsPerKilometre > 0 else { return "—" }

        let seconds: Double
        let suffix: String
        switch units {
        case .metric:
            seconds = secondsPerKilometre
            suffix = "/km"
        case .imperial:
            seconds = secondsPerKilometre * (metresPerMile / 1_000)
            suffix = "/mi"
        }

        let roundedSeconds = Int(seconds.rounded())
        return String(format: "%d:%02d %@", roundedSeconds / 60, roundedSeconds % 60, suffix)
    }

    public static func duration(seconds: TimeInterval) -> String {
        let totalSeconds = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    public static func elevationGain(metres: Double?, units: UnitPreference) -> String {
        guard let metres, metres.isFinite, metres >= 0 else { return "—" }
        switch units {
        case .metric:
            return String(format: "%.0f m", locale: posixLocale, metres)
        case .imperial:
            return String(format: "%.0f ft", locale: posixLocale, metres * feetPerMetre)
        }
    }
}
