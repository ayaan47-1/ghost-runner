import Foundation

public enum GPXParserError: Error, Equatable, LocalizedError, Sendable {
    case malformedXML
    case noTimedTrackPoints
    case noReplayableRoute
    case fileTooLarge(maximumMegabytes: Int)

    public var errorDescription: String? {
        switch self {
        case .malformedXML:
            return "This GPX file is malformed and could not be read."
        case .noTimedTrackPoints:
            return "This GPX file has no timed track points to replay."
        case .noReplayableRoute:
            return "This GPX file does not contain enough timed movement to replay."
        case .fileTooLarge(let maximumMegabytes):
            return "This GPX file is larger than the \(maximumMegabytes) MB import limit."
        }
    }
}

public struct GPXTrackPoint: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let elevationMetres: Double?
    public let timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        elevationMetres: Double?,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevationMetres = elevationMetres
        self.timestamp = timestamp
    }

    public var geoPoint: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    public var timedRoutePoint: TimedRoutePoint {
        TimedRoutePoint(
            point: geoPoint,
            altitude: elevationMetres ?? 0,
            hasReliableAltitude: elevationMetres != nil,
            timestamp: timestamp.timeIntervalSinceReferenceDate
        )
    }
}

public struct ParsedGPX: Equatable, Sendable {
    public let name: String?
    public let segments: [[GPXTrackPoint]]
    public let startDate: Date
    public let duration: TimeInterval
    public let distanceMetres: Double

    init(name: String?, segments: [[GPXTrackPoint]]) throws {
        let orderedSegments = segments.compactMap { segment -> [GPXTrackPoint]? in
            let ordered = segment.sorted { $0.timestamp < $1.timestamp }
            return ordered.isEmpty ? nil : ordered
        }
        let points = orderedSegments.flatMap { $0 }
        guard let first = points.min(by: { $0.timestamp < $1.timestamp }),
              let last = points.max(by: { $0.timestamp < $1.timestamp }) else {
            throw GPXParserError.noTimedTrackPoints
        }
        self.name = name
        self.segments = orderedSegments
        startDate = first.timestamp
        duration = max(0, last.timestamp.timeIntervalSince(first.timestamp))
        distanceMetres = RoutePath(parts: orderedSegments.map { $0.map(\.geoPoint) }).totalDistance
    }
}

public struct ImportedRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let sourceName: String
    public let importedAt: Date
    public let startDate: Date
    public let duration: TimeInterval
    public let distanceMetres: Double
    public let segments: [[GPXTrackPoint]]

    init(
        parsed: ParsedGPX,
        sourceName: String,
        id: UUID = UUID(),
        importedAt: Date = Date()
    ) {
        self.id = id
        name = parsed.name ?? URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        self.sourceName = sourceName
        self.importedAt = importedAt
        startDate = parsed.startDate
        duration = parsed.duration
        distanceMetres = parsed.distanceMetres
        segments = parsed.segments
    }

    public var timedRouteParts: [[TimedRoutePoint]] {
        segments.map { $0.map(\.timedRoutePoint) }
    }

    public var routeTimeline: RouteTimeline {
        RouteTimeline(parts: timedRouteParts)
    }
}

public enum ReplayRunSource: String, Codable, Equatable, Sendable {
    case health
    case gpx
}

public struct ReplayRunSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String?
    public let startDate: Date
    public let duration: TimeInterval
    public let distanceMetres: Double
    public let source: ReplayRunSource

    public init(
        id: UUID,
        name: String?,
        startDate: Date,
        duration: TimeInterval,
        distanceMetres: Double,
        source: ReplayRunSource
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.duration = duration
        self.distanceMetres = distanceMetres
        self.source = source
    }
}

public extension ImportedRun {
    var summary: ReplayRunSummary {
        ReplayRunSummary(
            id: id,
            name: name,
            startDate: startDate,
            duration: duration,
            distanceMetres: distanceMetres,
            source: .gpx
        )
    }
}

public actor ImportedRunStore {
    public static let maximumImportBytes = 20 * 1_024 * 1_024
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedRuns", isDirectory: true)
    }

    public func load() throws -> [ImportedRun] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder()
        return try urls.map { try decoder.decode(ImportedRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startDate > $1.startDate }
    }

    @discardableResult
    public func importGPX(data: Data, sourceName: String) throws -> ImportedRun {
        try validateImportSize(data.count)
        let parsed = try GPXParser.parse(data: data)
        let run = ImportedRun(parsed: parsed, sourceName: sourceName)
        guard run.routeTimeline.path.isPlayable, run.duration > 0 else {
            throw GPXParserError.noReplayableRoute
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destination = fileURL(id: run.id)
        try JSONEncoder().encode(run).write(to: destination, options: .atomic)
        return run
    }

    @discardableResult
    public func importGPX(from url: URL) throws -> ImportedRun {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            try validateImportSize(fileSize)
        }
        return try importGPX(data: Data(contentsOf: url), sourceName: url.lastPathComponent)
    }

    public func delete(id: UUID) throws {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func validateImportSize(_ byteCount: Int) throws {
        guard byteCount <= Self.maximumImportBytes else {
            throw GPXParserError.fileTooLarge(maximumMegabytes: 20)
        }
    }
}

public enum GPXParser {
    public static func parse(data: Data) throws -> ParsedGPX {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw GPXParserError.malformedXML }
        return try ParsedGPX(name: delegate.trackName, segments: delegate.segments)
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private struct PendingPoint {
        let latitude: Double
        let longitude: Double
        var elevationMetres: Double?
        var timestamp: Date?
    }

    private(set) var trackName: String?
    private(set) var segments: [[GPXTrackPoint]] = []
    private var currentSegment: [GPXTrackPoint]?
    private var currentPoint: PendingPoint?
    private var text = ""
    private var trackDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = localName(elementName)
        text = ""
        switch element {
        case "trk":
            trackDepth += 1
        case "trkseg":
            currentSegment = []
        case "trkpt":
            guard currentSegment != nil,
                  let latitudeText = attributeDict["lat"],
                  let longitudeText = attributeDict["lon"],
                  let latitude = Double(latitudeText),
                  let longitude = Double(longitudeText),
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else {
                currentPoint = nil
                return
            }
            currentPoint = PendingPoint(
                latitude: latitude,
                longitude: longitude,
                elevationMetres: nil,
                timestamp: nil
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "name" where trackDepth > 0 && trackName == nil && !value.isEmpty:
            trackName = value
        case "ele":
            currentPoint?.elevationMetres = Double(value)
        case "time":
            currentPoint?.timestamp = parseDate(value)
        case "trkpt":
            if let point = currentPoint, let timestamp = point.timestamp {
                currentSegment?.append(GPXTrackPoint(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    elevationMetres: point.elevationMetres,
                    timestamp: timestamp
                ))
            }
            currentPoint = nil
        case "trkseg":
            if let currentSegment, !currentSegment.isEmpty {
                segments.append(currentSegment)
            }
            currentSegment = nil
        case "trk":
            trackDepth = max(0, trackDepth - 1)
        default:
            break
        }
        text = ""
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
