import Foundation
import RPData

#if os(macOS)
    import AppKit
#endif

/// The single app instance for every entry point: windows, App Intents (which can run without any window),
/// the macOS menu bar and Services. Opening one SwiftData store twice in a process is unsafe, so everything
/// goes through here.
@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    /// Created on first use (the app's scene or an intent, whichever comes first).
    private(set) lazy var launch = LaunchModel()
    private var injected: AppModel?
    /// Opens a main window (macOS), registered by the first window so Services and the menu bar can show results
    /// when every window is closed.
    var openMainWindow: (() -> Void)?

    private init() {}

    /// The loaded app model for background work (intents, Services).
    func loadedModel() async throws(RuntimeError) -> AppModel {
        let model: AppModel
        if let injected {
            model = injected
        } else {
            switch launch.state {
            case .ready(let ready): model = ready
            case .failed(let error): throw .unavailable(error.message.isEmpty ? error.title : error.message)
            }
        }
        await model.load()
        return model
    }

    /// Asks a window to show `target`, bringing RequestPad forward and opening a window if none is visible (macOS).
    func show(_ target: OpenTarget, in model: AppModel) {
        model.requestedOpen = target
        #if os(macOS)
            NSApplication.shared.activate()
            if !NSApplication.shared.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openMainWindow?() }
        #endif
    }

    /// Tests run intents and handlers against an isolated model.
    func install(_ model: AppModel?) {
        injected = model
    }

    enum RuntimeError: Error, LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): String(localized: "RequestPad couldn't open its data. \(reason)")
            }
        }
    }
}
