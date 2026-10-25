import Foundation
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            NavigationStack { CockpitView() }
                .tabItem { Label("Cockpit", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(AppTab.cockpit)
            NavigationStack { SoundsView() }
                .tabItem { Label("Sounds", systemImage: "waveform") }
                .tag(AppTab.sounds)
            NavigationStack { ConnectionView() }
                .tabItem { Label("Verbindung", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.connection)
            NavigationStack { SettingsView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isDemoMode {
                DemoBanner()
            }
        }
        .sheet(isPresented: $model.showGuide) {
            NavigationStack {
                GuideView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { model.showGuide = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
    }
}
