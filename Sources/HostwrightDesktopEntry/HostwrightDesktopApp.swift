import SwiftUI
import HostwrightDesktopModel
import HostwrightDesktopUI

@main
struct HostwrightDesktopApp: App {
    @StateObject private var model = DesktopOperationsModel.live()

    var body: some Scene {
        WindowGroup(id: "operations") {
            OperationsConsoleView()
                .environmentObject(model)
        }
        .defaultSize(width: 1_180, height: 760)

        MenuBarExtra {
            MenuBarHealthView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
