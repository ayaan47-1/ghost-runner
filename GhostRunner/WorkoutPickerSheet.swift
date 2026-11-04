@preconcurrency import HealthKit
import SwiftUI

struct RecentRunsView: View {
    let workouts: [HKWorkout]
    let selectedWorkout: HKWorkout?
    let units: UnitPreference
    let onSelect: (UUID) -> Void
    var body: some View {
        NavigationStack {
            Group {
                if workouts.isEmpty {
                    ContentUnavailableView(
                        "No Runs Found",
                        systemImage: "figure.run",
                        description: Text("Allow Health access or record an outdoor run first.")
                    )
                } else {
                    List(workouts.sorted { $0.startDate > $1.startDate }, id: \.uuid) { workout in
                        let isSelected = workout.uuid == selectedWorkout?.uuid
                        Button {
                            onSelect(workout.uuid)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workout.startDate, format: .dateTime.weekday(.abbreviated).month().day())
                                        .font(.body.weight(.semibold))
                                    Text(workout.startDate, format: .dateTime.hour().minute())
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(RunFormatting.distance(
                                        metres: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                                        units: units
                                    ))
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .monospacedDigit()
                                    Text(RunFormatting.duration(seconds: workout.duration))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(GhostRunnerPalette.actionBlue)
                                }
                            }
                            .frame(minHeight: 72)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recent Runs")
            .background(GhostRunnerPalette.canvas)
        }
    }
}
