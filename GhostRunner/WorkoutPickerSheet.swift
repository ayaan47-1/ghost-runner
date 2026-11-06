import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

struct RecentRunsView: View {
    let runs: [ReplayRunSummary]
    let selectedRunID: UUID?
    let units: UnitPreference
    let onSelect: (UUID) -> Void
    let onImport: (URL) -> Void
    let onDelete: (UUID) -> Void
    @State private var showsImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView {
                        Label("No Runs Found", systemImage: "figure.run")
                    } description: {
                        Text("Import a GPX file or allow Health access to choose a run.")
                    } actions: {
                        importButton
                    }
                } else {
                    List(runs) { run in
                        Button {
                            onSelect(run.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(run.name ?? run.startDate.formatted(
                                            .dateTime.weekday(.abbreviated).month().day()
                                        ))
                                            .font(.body.weight(.semibold))
                                        if run.source == .gpx {
                                            Text("GPX")
                                                .font(.caption2.weight(.bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    GhostRunnerPalette.actionBlue.opacity(0.14),
                                                    in: Capsule()
                                                )
                                        }
                                    }
                                    Text(run.startDate, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(RunFormatting.distance(metres: run.distanceMetres, units: units))
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .monospacedDigit()
                                    Text(RunFormatting.duration(seconds: run.duration))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if run.id == selectedRunID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(GhostRunnerPalette.actionBlue)
                                }
                            }
                            .frame(minHeight: 72)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(run.id == selectedRunID ? .isSelected : [])
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if run.source == .gpx {
                                Button(role: .destructive) { onDelete(run.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recent Runs")
            .toolbar {
                if !runs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { importButton }
                }
            }
            .background(GhostRunnerPalette.canvas)
            .fileImporter(
                isPresented: $showsImporter,
                allowedContentTypes: [.gpx],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                onImport(url)
            }
        }
    }

    private var importButton: some View {
        Button { showsImporter = true } label: {
            Label("Import GPX", systemImage: "square.and.arrow.down")
                .frame(minHeight: 44)
        }
    }
}
