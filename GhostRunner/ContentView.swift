import SwiftUI
import UIKit

private enum AppTab: Hashable {
    case replay
    case runs
    case account
}

struct ContentView: View {
    @State private var viewModel = GhostRunnerViewModel()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("unitSetting") private var unitSettingRaw = UnitSetting.automatic.rawValue
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed = 1.0
    @State private var selectedTab = AppTab.replay
    @State private var tabContentFrame = CGRect.zero
#if DEBUG
    @AppStorage("showsLayoutDebugOverlay") private var showsLayoutDebugOverlay = false
#endif
    @Environment(\.openURL) private var openURL

    var body: some View {
        TabView(selection: $selectedTab) {
            replayScreen
                .reportTabContentFrame()
                .tabItem { Label("Replay", systemImage: "map") }
                .tag(AppTab.replay)

            RecentRunsView(
                workouts: viewModel.recentRuns,
                selectedWorkout: viewModel.selectedWorkout,
                units: viewModel.unitPreference
            ) { workoutID in
                selectedTab = .replay
                Task { await viewModel.selectWorkout(id: workoutID) }
            }
            .reportTabContentFrame()
            .tabItem { Label("Runs", systemImage: "list.bullet") }
            .tag(AppTab.runs)

            AccountView(viewModel: viewModel) {
                viewModel.isWelcomeGuidePresented = true
            }
            .reportTabContentFrame()
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
            .tag(AppTab.account)
        }
        .tint(GhostRunnerPalette.actionBlue)
        .background(GhostRunnerPalette.canvas)
        .onPreferenceChange(TabContentFrameKey.self) { tabContentFrame = $0 }
        .tabBarDebugFrame(contentFrame: tabContentFrame, enabled: layoutDebugEnabled)
        .task(id: hasSeenWelcome) {
            applyStoredPreferences()
            guard hasSeenWelcome else { return }
            await viewModel.load()
        }
        .onChange(of: unitSettingRaw) { _, _ in applyStoredPreferences() }
        .onChange(of: defaultPlaybackSpeed) { _, _ in applyStoredPreferences() }
        .fullScreenCover(isPresented: welcomePresentation) {
            WelcomeGuideView(onFinish: completeWelcome)
        }
    }

    private var layoutDebugEnabled: Bool {
#if DEBUG
        showsLayoutDebugOverlay
#else
        false
#endif
    }

    private var replayScreen: some View {
        ZStack {
            GhostRunnerMapView(viewModel: viewModel) { selectedTab = .runs }

            switch viewModel.loadState {
            case .idle, .loading:
                stateCard(systemImage: "figure.run", title: "Loading runs…") {
                    ProgressView().controlSize(.large)
                }
            case .empty(let title, let message):
                stateCard(systemImage: "map", title: title, message: message) {
                    if !viewModel.recentRuns.isEmpty {
                        Button("Choose Another Run") { selectedTab = .runs }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Try Again") { Task { await viewModel.retry() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if viewModel.shouldOfferHealthSettings { openSettingsButton }
                }
            case .failed(let message):
                stateCard(systemImage: "heart.slash", title: "Runs Unavailable", message: message) {
                    if !viewModel.recentRuns.isEmpty {
                        Button("Choose Another Run") { selectedTab = .runs }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Try Again") { Task { await viewModel.retry() } }
                        .buttonStyle(.borderedProminent)
                    if viewModel.shouldOfferHealthSettings { openSettingsButton }
                }
            case .ready:
                EmptyView()
            }
        }
        .background(GhostRunnerPalette.canvas)
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
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(GhostRunnerPalette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var welcomePresentation: Binding<Bool> {
        Binding(
            get: {
                WelcomeGate.shouldPresent(
                    hasSeenWelcome: hasSeenWelcome,
                    reopenRequested: viewModel.isWelcomeGuidePresented
                )
            },
            set: { presented in
                if !presented { completeWelcome() }
            }
        )
    }

    private func completeWelcome() {
        hasSeenWelcome = true
        viewModel.isWelcomeGuidePresented = false
    }

    private func applyStoredPreferences() {
        viewModel.applyPreferences(
            unitSetting: UnitSetting(rawValue: unitSettingRaw) ?? .automatic,
            defaultPlaybackSpeed: defaultPlaybackSpeed
        )
    }

    private var openSettingsButton: some View {
        Button("Open Settings") {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }
}

private struct WelcomeGuideView: View {
    struct Page {
        let symbol: String
        let title: String
        let message: String
    }

    let onFinish: () -> Void
    @State private var page = 0

    private let pages = [
        Page(
            symbol: "figure.run.circle",
            title: "Race your past self",
            message: "Ghost Runner replays a past outdoor run as a moving ghost on the map."
        ),
        Page(
            symbol: "clock.arrow.circlepath",
            title: "Pick a run",
            message: "Open Recent Runs and choose any workout that includes an outdoor GPS route."
        ),
        Page(
            symbol: "play.circle",
            title: "Control the replay",
            message: "Play or pause, change speed, drag the scrubber, and recenter the route after exploring the map."
        ),
        Page(
            symbol: "heart.text.square",
            title: "Splits and Health",
            message: "See observed splits when your run has timing data. Health access lets us read your workouts and routes; Ghost Runner never writes or uploads them."
        )
    ]

    var body: some View {
        ZStack {
            GhostRunnerPalette.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip", action: onFinish)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        welcomePage(pages[index], index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
        }
        .foregroundStyle(GhostRunnerPalette.ink)
        .interactiveDismissDisabled()
    }

    private func welcomePage(_ item: Page, index: Int) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: item.symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(GhostRunnerPalette.actionBlue)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(item.message)
                .font(.body)
                .foregroundStyle(GhostRunnerPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            if index == pages.count - 1 {
                Button("Get Started", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .tint(GhostRunnerPalette.actionBlue)
                    .foregroundStyle(GhostRunnerPalette.onAction)
            } else {
                Button("Next") { withAnimation { page = index + 1 } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .tint(GhostRunnerPalette.actionBlue)
                    .foregroundStyle(GhostRunnerPalette.onAction)
            }
            Spacer().frame(height: 52)
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }
}

private struct AccountView: View {
    @Bindable var viewModel: GhostRunnerViewModel
    let onShowWelcome: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("profileName") private var profileName = "Runner"
    @AppStorage("unitSetting") private var unitSettingRaw = UnitSetting.automatic.rawValue
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed = 1.0
#if DEBUG
    @AppStorage("showsLayoutDebugOverlay") private var showsLayoutDebugOverlay = false
#endif

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profileCard
                    runningCard
                    preferencesCard
                    healthCard
#if DEBUG
                    developerCard
#endif
                    aboutCard
                }
                .padding(20)
            }
            .background(GhostRunnerPalette.canvas)
            .navigationTitle("Account")
        }
        .task {
            applyPreferences()
            await viewModel.loadRunningTotals()
        }
        .onChange(of: unitSettingRaw) { _, _ in applyPreferences() }
        .onChange(of: defaultPlaybackSpeed) { _, _ in applyPreferences() }
    }

    private var profileCard: some View {
        accountSection("LOCAL PROFILE") {
            HStack(spacing: 16) {
                Text(initials)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(GhostRunnerPalette.onAction)
                    .frame(width: 56, height: 56)
                    .background(GhostRunnerPalette.actionBlue, in: Circle())
                    .accessibilityLabel("Profile initials, \(initials)")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.footnote).foregroundStyle(GhostRunnerPalette.inkSecondary)
                    TextField("Runner", text: $profileName)
                        .font(.headline)
                        .textInputAutocapitalization(.words)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private var runningCard: some View {
        accountSection("YOUR RUNNING") {
            if viewModel.isRunningTotalsLoading {
                ProgressView("Loading totals…").frame(maxWidth: .infinity, minHeight: 80)
            } else if let error = viewModel.runningTotalsError {
                Text(error).font(.body).foregroundStyle(GhostRunnerPalette.inkSecondary)
            } else {
                totalsLayout
            }
        }
    }

    private var preferencesCard: some View {
        accountSection("PREFERENCES") {
            preferenceRow("Units") {
                Picker("Units", selection: $unitSettingRaw) {
                    Text("Automatic").tag(UnitSetting.automatic.rawValue)
                    Text("Metric").tag(UnitSetting.metric.rawValue)
                    Text("Imperial").tag(UnitSetting.imperial.rawValue)
                }
                .labelsHidden()
            }
            Divider().overlay(GhostRunnerPalette.hairline)
            preferenceRow("Default playback speed") {
                Picker("Default playback speed", selection: $defaultPlaybackSpeed) {
                    ForEach(viewModel.playbackSpeeds, id: \.self) { speed in
                        Text("\(speed, specifier: "%.0f")×").tag(speed)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var healthCard: some View {
        accountSection("HEALTH ACCESS") {
            Text(viewModel.healthAccessSummary)
                .font(.body)
                .foregroundStyle(GhostRunnerPalette.inkSecondary)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(GhostRunnerPalette.actionBlue)
            .foregroundStyle(GhostRunnerPalette.onAction)
            Button {
                onShowWelcome()
            } label: {
                Label("Show welcome guide", systemImage: "book.pages")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(GhostRunnerPalette.actionBlue)
            .foregroundStyle(GhostRunnerPalette.onAction)
        }
    }

    private var aboutCard: some View {
        accountSection("ABOUT") {
            HStack {
                Text("Ghost Runner")
                Spacer()
                Text("Version \(appVersion)").foregroundStyle(GhostRunnerPalette.inkSecondary)
            }
            .font(.body)
            .frame(minHeight: 44)
            Divider().overlay(GhostRunnerPalette.hairline)
            ForEach(AppSettings.accountLinks) { link in
                Link(destination: link.url) {
                    HStack {
                        Label(link.title, systemImage: "hand.raised")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in your web browser")
            }
        }
    }

#if DEBUG
    private var developerCard: some View {
        accountSection("DEVELOPER") {
            Toggle("Show layout measurements", isOn: $showsLayoutDebugOverlay)
                .frame(minHeight: 44)
        }
    }
#endif

    private func accountSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GhostRunnerPalette.inkSecondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(GhostRunnerPalette.ink)
        .background(GhostRunnerPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(GhostRunnerPalette.hairline))
    }

    private func preferenceRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            control()
        }
        .frame(minHeight: 44)
    }

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(GhostRunnerPalette.inkSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    @ViewBuilder
    private var totalsLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 16) { totalCells }
        } else {
            LazyVGrid(columns: columns, spacing: 16) { totalCells }
        }
    }

    @ViewBuilder
    private var totalCells: some View {
        total("TOTAL RUNS", "\(viewModel.runningTotals.runCount)")
        total("TOTAL DISTANCE", distance(viewModel.runningTotals.totalDistanceMetres))
        total("LONGEST RUN", distance(viewModel.runningTotals.longestRunMetres))
        total("THIS WEEK", distance(viewModel.runningTotals.thisWeekDistanceMetres))
    }

    private func distance(_ metres: Double) -> String {
        RunFormatting.distance(metres: metres, units: viewModel.unitPreference)
    }

    private var initials: String {
        let letters = profileName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "GR" : String(letters).uppercased()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func applyPreferences() {
        viewModel.applyPreferences(
            unitSetting: UnitSetting(rawValue: unitSettingRaw) ?? .automatic,
            defaultPlaybackSpeed: defaultPlaybackSpeed
        )
    }
}

private struct TabContentFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private extension View {
    func reportTabContentFrame() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: TabContentFrameKey.self, value: geometry.frame(in: .global))
            }
        }
    }

    @ViewBuilder
    func tabBarDebugFrame(contentFrame: CGRect, enabled: Bool) -> some View {
#if DEBUG
        if enabled, contentFrame != .zero {
            overlay {
                GeometryReader { geometry in
                    let rootFrame = geometry.frame(in: .global)
                    let top = max(contentFrame.maxY, rootFrame.minY)
                    let height = max(0, rootFrame.maxY - top)
                    ZStack(alignment: .topLeading) {
                        Rectangle().stroke(.pink, lineWidth: 1)
                        Text("TAB BAR y \(top, specifier: "%.0f") · h \(height, specifier: "%.0f")")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.pink)
                    }
                    .frame(width: rootFrame.width, height: height)
                    .position(x: rootFrame.width / 2, y: top - rootFrame.minY + height / 2)
                    .allowsHitTesting(false)
                }
            }
        } else {
            self
        }
#else
        self
#endif
    }
}
