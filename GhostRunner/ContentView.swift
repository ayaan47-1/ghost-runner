import SwiftUI

struct ContentView: View {
    @State private var viewModel = GhostRunnerViewModel()

    var body: some View {
        ZStack {
            GhostRunnerMapView(viewModel: viewModel)

            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView("Loading runs…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .empty(let title, let message):
                emptyState(title: title, message: message, systemImage: "map")
            case .failed(let message):
                emptyState(title: "Health Access Needed", message: message, systemImage: "heart.slash")
            case .ready:
                EmptyView()
            }
        }
        .ignoresSafeArea()
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.isWorkoutPickerPresented) {
            WorkoutPickerSheet(
                workouts: viewModel.recentRuns,
                selectedWorkout: viewModel.selectedWorkout
            ) { workoutID in
                Task { await viewModel.selectWorkout(id: workoutID) }
            }
        }
    }

    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding()
    }
}
