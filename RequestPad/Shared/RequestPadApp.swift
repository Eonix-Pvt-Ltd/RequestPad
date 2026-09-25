import RPData
import RPServices
import SwiftUI

@main
struct RequestPadApp: App {
    @State private var launch = LaunchModel()

    var body: some Scene {
        WindowGroup {
            RootView(launch: launch)
        }
    }
}
