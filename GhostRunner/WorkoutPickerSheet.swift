@preconcurrency import HealthKit
import SwiftUI

struct WorkoutPickerSheet: View {
    let workouts: [HKWorkout]
    let selectedWorkout: HKWorkout?
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Recent Runs")
                        .font(.system(size: 28, weight: .bold))
                    Spacer()
                    Button("Close") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

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
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workout.startDate, format: .dateTime.weekday(.abbreviated).month().day())
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(workout.startDate, format: .dateTime.hour().minute())
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(RunFormatting.distance(
                                        metres: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                                        units: Locale.current.measurementSystem == .metric ? .metric : .imperial
                                    ))
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    Text(RunFormatting.duration(seconds: workout.duration))
                                        .font(.system(size: 13))
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
        }
        .presentationDetents([.medium, .large])
    }
}
