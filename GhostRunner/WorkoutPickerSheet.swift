@preconcurrency import HealthKit
import SwiftUI

struct WorkoutPickerSheet: View {
    let workouts: [HKWorkout]
    let selectedWorkout: HKWorkout?
    let onSelect: (HKWorkout) -> Void
    @Environment(\.dismiss) private var dismiss

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
                    List(workouts, id: \.uuid) { workout in
                        Button {
                            onSelect(workout)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(workout.startDate, format: .dateTime.weekday(.abbreviated).month().day())
                                        .font(.headline)
                                    Text(workout.startDate, format: .dateTime.hour().minute())
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(RunFormatting.distance(
                                        metres: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                                        units: Locale.current.measurementSystem == .metric ? .metric : .imperial
                                    ))
                                    Text(RunFormatting.duration(seconds: workout.duration))
                                        .foregroundStyle(.secondary)
                                }
                                if workout.uuid == selectedWorkout?.uuid {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Recent Runs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
