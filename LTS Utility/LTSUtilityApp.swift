import SwiftUI
import AppKit

@main
struct LTSUtilityApp: App {
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("LTS Utility", id: "main") {
            MainFlasherView()
                .frame(width: 336, height: 338)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                }
            }
        }
    }
}
