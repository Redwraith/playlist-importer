import SwiftUI

@main
struct PlaylistImporterApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
            #if DEBUG
                .onAppear { model.applyScreenshotStep() }
            #endif
        }
    }
}
