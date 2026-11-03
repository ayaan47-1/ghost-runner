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

public enum RouteMath {
    public static func fittedRegion(
        for points: [GeoPoint],
        paddingFactor: Double = 1.25,
        minimumSpan: Double = 0.002
    ) -> RouteRegion? {
        guard let first = points.first else { return nil }

        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude
        var minimumLongitude = first.longitude
        var maximumLongitude = first.longitude

        for point in points.dropFirst() {
            minimumLatitude = min(minimumLatitude, point.latitude)
            maximumLatitude = max(maximumLatitude, point.latitude)
            minimumLongitude = min(minimumLongitude, point.longitude)
            maximumLongitude = max(maximumLongitude, point.longitude)
        }

        let safePadding = max(1, paddingFactor)
        let safeMinimumSpan = max(0.000_001, minimumSpan)
        let latitudeDelta = max(safeMinimumSpan, (maximumLatitude - minimumLatitude) * safePadding)
        let longitudeDelta = max(safeMinimumSpan, (maximumLongitude - minimumLongitude) * safePadding)

        return RouteRegion(
            center: GeoPoint(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }
}

public enum PlaybackMath {
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
