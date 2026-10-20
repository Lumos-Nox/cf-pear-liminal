import SwiftUI

@main
struct PearLiminalApp: App {
    @State private var model = AppModel()
    @State private var isLaunching = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if isLaunching {
                    LaunchSplashView()
                } else {
                    ContentView()
                        .environment(model)
                }
            }
                .task { await model.restoreSession() }
                .task {
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                    isLaunching = false
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setAppActive(phase == .active, isBackgrounded: phase == .background)
                }
        }
    }
}

private struct LaunchSplashView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Image("LaunchIconRounded")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityLabel("Pear Liminal")
        }
        .ignoresSafeArea()
    }
}
