import MapKit
import SwiftUI

struct GhostRunnerMapView: View {
    @Bindable var viewModel: GhostRunnerViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            if !viewModel.routeCoordinates.isEmpty {
                MapPolyline(coordinates: viewModel.routeCoordinates)
                    .stroke(.blue.gradient, lineWidth: 5)
            }

            if let ghostCoordinate = viewModel.ghostCoordinate {
                Annotation("Ghost", coordinate: ghostCoordinate) {
                    GhostPuck()
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .onChange(of: viewModel.routeCoordinates.count) { _, _ in
            fitRoute()
        }
        .overlay(alignment: .bottom) {
            controlDock
                .padding()
        }
    }

    private var controlDock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pause ghost" : "Play ghost")

                Slider(
                    value: Binding(
                        get: { viewModel.scrubberValue },
                        set: { viewModel.scrubberValue = $0 }
                    ),
                    in: 0...viewModel.maximumScrubberValue
                )
                .disabled(viewModel.routeCoordinates.count < 2)

                Menu("\(viewModel.playbackSpeed, specifier: "%.0f")×") {
                    ForEach(viewModel.playbackSpeeds, id: \.self) { speed in
                        Button("\(speed, specifier: "%.0f")×") {
                            viewModel.playbackSpeed = speed
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack {
                stat("CURRENT SPLIT", viewModel.formattedCurrentSplit)
                stat("AVG PACE", viewModel.formattedPace)
            }

            HStack {
                stat("DISTANCE", viewModel.formattedDistance)
                stat("DURATION", viewModel.formattedDuration)
                stat("ELEVATION", viewModel.formattedElevationGain)
            }

            Button {
                viewModel.isWorkoutPickerPresented = true
            } label: {
                Label("Choose a run", systemImage: "figure.run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func fitRoute() {
        let points = viewModel.routeCoordinates.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard let fit = RouteMath.fittedRegion(for: points) else { return }
        cameraPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: fit.center.latitude,
                    longitude: fit.center.longitude
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: fit.latitudeDelta,
                    longitudeDelta: fit.longitudeDelta
                )
            )
        )
    }
}

private struct GhostPuck: View {
    var body: some View {
        Circle()
            .fill(.orange)
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .orange, radius: 12)
            .shadow(color: .orange.opacity(0.7), radius: 4)
            .accessibilityHidden(true)
    }
}
