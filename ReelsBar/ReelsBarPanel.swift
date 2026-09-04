import SwiftUI

struct ReelsBarPanel: View {
    @Environment(AppModel.self) private var appModel
    // TEMP-DIAG: on-panel diagnostics. Remove once scroll is fixed.
    private let showDebug = true

    var body: some View {
        ZStack(alignment: .top) {
            ReelsWebView()

            if appModel.isReelsTab {
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        if appModel.isAutoScrollActive {
                            Label("Auto", systemImage: "arrow.down.circle.fill")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        Button {
                            appModel.toggleMute()
                        } label: {
                            Image(systemName: appModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .help(appModel.isMuted ? "Unmute (M)" : "Mute (M)")
                    }
                    .padding(.horizontal, 8)
                }
            }

            // TEMP-DIAG: always visible (even off the Reels tab) so a
            // screenshot reveals native state + bridge liveness.
            if showDebug {
                VStack(alignment: .leading, spacing: 2) {
                    Text("tab:\(appModel.isReelsTab ? "Y" : "N") active:\(appModel.isPanelActive ? "Y" : "N") last:\(appModel.lastAction)")
                    Text("bridge: \(appModel.bridgeInfo)")
                    Button("Ping bridge") { appModel.pingBridge() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(6)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            width: appModel.isReelMode ? AppModel.reelSize.width : AppModel.panelSize.width,
            height: appModel.isReelMode ? AppModel.reelSize.height : AppModel.panelSize.height
        )
        .ignoresSafeArea()
    }
}
