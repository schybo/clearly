import SwiftData
import SwiftUI

#if os(iOS)
struct MainTabView: View {
    @AppStorage("wisk.ios.appearance") private var appearanceRawValue = WiskAppearance.system.rawValue
    @AppStorage(WiskBetaFeatures.plaudEnabledKey) private var plaudEnabled = false
    @State private var selection = 0
    @State private var notesPath: [UUID] = []
    @State private var reviewPath: [UUID] = []

    private var appearance: WiskAppearance {
        WiskAppearance(rawValue: appearanceRawValue) ?? .system
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Notes", systemImage: "note.text", value: 0) {
                WiskIOSNotesRoot(navigationPath: $notesPath)
            }

            Tab("Buckets", systemImage: "square.stack.3d.up", value: 1) {
                NavigationStack(path: $reviewPath) {
                    ReviewQueueView()
                }
                .environment(\.wiskOpenNote, { reviewPath.append($0) })
            }

            Tab("Settings", systemImage: "gearshape", value: 2) {
                NavigationStack {
                    SettingsView()
                }
            }

            #if DEBUG
            if plaudEnabled {
                Tab("Plaud", systemImage: "waveform.badge.magnifyingglass", value: 3) {
                    NavigationStack {
                        PlaudImportTestView()
                    }
                }
            }
            #endif
        }
        .tint(.accent)
        .preferredColorScheme(appearance.colorScheme)
    }
}
#endif
