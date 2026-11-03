import SwiftUI

struct ContentView: View {
    @State private var viewModel = GhostRunnerViewModel()

    var body: some View {
        ZStack {
            GhostRunnerMapView(viewModel: viewModel)

            switch viewModel.loadState {
            case .idle, .loading:
                stateCard(systemImage: "figure.run", title: "Loading runs…") {
                    ProgressView().controlSize(.large)
                }
            case .empty(let title, let message):
                stateCard(systemImage: "map", title: title, message: message) {
                    if !viewModel.recentRuns.isEmpty {
                        Button("Choose Another Run") { viewModel.isWorkoutPickerPresented = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Try Again") { Task { await viewModel.retry() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .failed(let message):
                stateCard(systemImage: "heart.slash", title: "Runs Unavailable", message: message) {
                    Button("Try Again") { Task { await viewModel.retry() } }
                        .buttonStyle(.borderedProminent)
                }
            case .ready:
                EmptyView()
            }
        }
        .background(GhostRunnerPalette.canvas)
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

    private func stateCard<Actions: View>(
        systemImage: String,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(GhostRunnerPalette.actionBlue)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(GhostRunnerPalette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            actions()
        }
        .foregroundStyle(GhostRunnerPalette.ink)
        .padding(20)
        .frame(maxWidth: 340)
        .background(GhostRunnerPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GhostRunnerPalette.hairline))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .padding(20)
    }
}
