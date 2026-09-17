import SwiftUI

struct ReelsBarPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack(alignment: .top) {
            ReelsWebView()

            if appModel.showDiag {
                VStack {
                    Text(
                        (appModel.diagLine.isEmpty ? "…" : appModel.diagLine)
                            .replacingOccurrences(of: " f=", with: "\nf=")
                            .replacingOccurrences(of: " dT=", with: "\ndT=")
                    )
                    .font(.system(size: 13, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 44)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            // Mute is global (videos exist outside reels and the watchdog
            // mutes them); the Auto badge stays reels-only.
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    if appModel.isReelsTab, appModel.isAutoScrollActive {
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
                .padding(.top, 8)
            }
        }
        .frame(
            width: AppModel.contentSize(forReelMode: appModel.isReelMode).width,
            height: AppModel.contentSize(forReelMode: appModel.isReelMode).height
        )
        .ignoresSafeArea()
    }
}
