import SwiftUI

@main
struct ReelsBarApp: App {
    @State private var appModel = AppModel()

    init() {
        let model = AppModel()
        _appModel = State(initialValue: model)
        model.startLifecycleObservation()
    }

    var body: some Scene {
        MenuBarExtra {
            ReelsBarPanel()
                .environment(appModel)
        } label: {
            Image(systemName: "play.rectangle.on.rectangle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
