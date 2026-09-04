import SwiftUI

@main
struct ReelsBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // REELSBAR_DEBUG=1 captures app + page logs to a file inside the
        // sandbox container. /tmp is not writable under App Sandbox, so only
        // the container temp dir is used; both stdout and stderr redirect.
        if ProcessInfo.processInfo.environment["REELSBAR_DEBUG"] == "1" {
            let path = NSTemporaryDirectory() + "reelsbar.log"
            _ = freopen(path, "a", stdout)
            _ = freopen(path, "a", stderr)
            setbuf(stdout, nil)
            setbuf(stderr, nil)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
