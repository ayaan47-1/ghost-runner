import MapKit
import SwiftUI
import UIKit

enum GhostRunnerPalette {
    static let canvas = dynamic(light: 0xF5F8FB, dark: 0x101923)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1B2935)
    static let ink = dynamic(light: 0x172B3D, dark: 0xF7FAFD)
    static let inkSecondary = dynamic(light: 0x526576, dark: 0xC6D4DF)
    static let hairline = dynamic(light: 0xD9E2EA, dark: 0x405369)
    static let actionBlue = dynamic(light: 0x2856A8, dark: 0x8BB7FF)
    static let route = actionBlue
    static let routeCasing = dynamic(light: 0xFFFFFF, dark: 0x101923)
    static let ghostCore = Color(red: 48 / 255, green: 213 / 255, blue: 192 / 255)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255,
                  green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255,
                  alpha: 1)
    }
}

struct GhostRunnerMapView: View {
    @Bindable var viewModel: GhostRunnerViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var fittedRegion: MKCoordinateRegion?
    @State private var showsRecenter = false

    var body: some View {
        GeometryReader { geometry in
            Map(position: $cameraPosition) {
                if !viewModel.routeCoordinates.isEmpty {
                    MapPolyline(coordinates: viewModel.routeCoordinates)
                        .stroke(GhostRunnerPalette.routeCasing, lineWidth: 8)
                    MapPolyline(coordinates: viewModel.routeCoordinates)
                        .stroke(GhostRunnerPalette.route, lineWidth: 4)
                }
                if let coordinate = viewModel.ghostCoordinate {
                    Annotation("Ghost runner", coordinate: coordinate) { GhostPuck() }
                        .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .accessibilityLabel("Route replay map")
            .accessibilityValue(viewModel.isPlaying ? "Ghost replay in progress" : "Ghost replay paused")
            .onChange(of: viewModel.routeCoordinates.count) { _, _ in
                fitRoute(in: geometry.size, safeAreaTop: geometry.safeAreaInsets.top)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                guard let fittedRegion else { return }
                showsRecenter = !approximatelyEqual(context.region, fittedRegion)
            }
            .overlay(alignment: .top) {
                runSummaryPanel
                    .frame(height: 118)
                    .padding(.horizontal, 20)
                    .padding(.top, geometry.safeAreaInsets.top + 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if showsRecenter && !viewModel.routeCoordinates.isEmpty {
                    Button {
                        fitRoute(in: geometry.size, safeAreaTop: geometry.safeAreaInsets.top)
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GhostRunnerPalette.actionBlue)
                    .background(GhostRunnerPalette.surface, in: Circle())
                    .overlay(Circle().stroke(GhostRunnerPalette.hairline))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.trailing, 16)
                    .padding(.bottom, 250 + geometry.safeAreaInsets.bottom)
                    .accessibilityLabel("Recenter route")
                }
            }
            .overlay(alignment: .bottom) { controlDock.padding() }
        }
    }

    private var runSummaryPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ghost Runner").font(.system(size: 15, weight: .semibold))
                    if let workout = viewModel.selectedWorkout {
                        Text(workout.startDate, format: .dateTime.weekday(.wide).month().day())
                            .font(.system(size: 13))
                            .foregroundStyle(GhostRunnerPalette.inkSecondary)
                    } else {
                        Text("Select a run")
                            .font(.system(size: 13))
                            .foregroundStyle(GhostRunnerPalette.inkSecondary)
                    }
                }
                Spacer()
                Button { viewModel.isWorkoutPickerPresented = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GhostRunnerPalette.actionBlue)
                .accessibilityLabel("Recent Runs")
            }
            HStack(spacing: 8) {
                summaryStat("DISTANCE", viewModel.formattedDistance)
                summaryStat("DURATION", viewModel.formattedDuration)
                summaryStat("AVG PACE", viewModel.formattedPace)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .foregroundStyle(GhostRunnerPalette.ink)
        .background(GhostRunnerPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GhostRunnerPalette.hairline))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private func summaryStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GhostRunnerPalette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlDock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 32, height: 32)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause ghost" : "Play ghost")
                Slider(value: Binding(get: { viewModel.scrubberValue }, set: { viewModel.scrubberValue = $0 }),
                       in: 0...viewModel.maximumScrubberValue)
                    .disabled(viewModel.routeCoordinates.count < 2)
                Menu("\(viewModel.playbackSpeed, specifier: "%.0f")×") {
                    ForEach(viewModel.playbackSpeeds, id: \.self) { speed in
                        Button("\(speed, specifier: "%.0f")×") { viewModel.playbackSpeed = speed }
                    }
                }.buttonStyle(.bordered)
            }
            HStack {
                dockStat("CURRENT SPLIT", viewModel.formattedCurrentSplit)
                dockStat("AVG PACE", viewModel.formattedPace)
            }
            HStack {
                dockStat("DISTANCE", viewModel.formattedDistance)
                dockStat("DURATION", viewModel.formattedDuration)
                dockStat("ELEVATION", viewModel.formattedElevationGain)
            }
        }
        .padding(16)
        .background(GhostRunnerPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func dockStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.subheadline, design: .rounded, weight: .bold)).lineLimit(1)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(GhostRunnerPalette.inkSecondary)
        }.frame(maxWidth: .infinity)
    }

    private func fitRoute(in size: CGSize, safeAreaTop: CGFloat) {
        let points = viewModel.routeCoordinates.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
        guard let fit = RouteMath.fittedRegion(for: points) else { return }
        let adjusted = RouteMath.adjustedForViewport(
            fit, viewportWidth: size.width, viewportHeight: size.height,
            topOcclusion: safeAreaTop + 150, bottomOcclusion: 240, horizontalInset: 24
        )
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: adjusted.center.latitude, longitude: adjusted.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: adjusted.latitudeDelta, longitudeDelta: adjusted.longitudeDelta)
        )
        fittedRegion = region
        showsRecenter = false
        cameraPosition = .region(region)
    }

    private func approximatelyEqual(_ left: MKCoordinateRegion, _ right: MKCoordinateRegion) -> Bool {
        let latitudeTolerance = max(right.span.latitudeDelta * 0.02, 0.000_01)
        let longitudeTolerance = max(right.span.longitudeDelta * 0.02, 0.000_01)
        return abs(left.center.latitude - right.center.latitude) <= latitudeTolerance
            && abs(left.center.longitude - right.center.longitude) <= longitudeTolerance
            && abs(left.span.latitudeDelta - right.span.latitudeDelta) <= latitudeTolerance
            && abs(left.span.longitudeDelta - right.span.longitudeDelta) <= longitudeTolerance
    }
}

private struct GhostPuck: View {
    var body: some View {
        Circle()
            .fill(GhostRunnerPalette.ghostCore)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color(red: 16 / 255, green: 25 / 255, blue: 35 / 255), lineWidth: 2))
            .padding(2)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .accessibilityHidden(true)
    }
}
