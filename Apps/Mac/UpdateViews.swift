import SwiftUI
import OmilDesign

struct UpdateCommands: Commands {
    @ObservedObject var updater: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

struct SidebarUpdateNotice: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        if let version = updater.availableVersion {
            VStack(alignment: .leading, spacing: 8) {
                Label("Update Available", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OmilTheme.ink)
                Text("Omil \(version) is ready to download.")
                    .font(OmilFont.caption)
                    .foregroundStyle(OmilTheme.muted)
                Button("Update Now", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .controlSize(.small)
                    .disabled(!updater.canCheckForUpdates)
                    .help("Download and install Omil \(version)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(OmilTheme.panelLifted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
