import SwiftUI

struct ReelsBarPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack(alignment: .top) {
            ReelsWebView()

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
        .frame(width: 375, height: 812)
        .ignoresSafeArea()
    }
}
