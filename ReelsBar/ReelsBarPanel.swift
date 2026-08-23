import SwiftUI

struct ReelsBarPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            Text("ReelsBar")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 375, height: 667)
    }
}
