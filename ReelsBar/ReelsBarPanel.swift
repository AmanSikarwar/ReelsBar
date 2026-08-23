import SwiftUI

struct ReelsBarPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            ReelsWebView()
        }
        .ignoresSafeArea()
        .frame(width: 375, height: 667)
    }
}
