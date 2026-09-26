#if os(macOS)
    import AppKit
    import OSLog
    import RPCore

    /// Registers the Services provider at launch (X01.3).
    final class AppDelegate: NSObject, NSApplicationDelegate {
        let services = ServicesProvider()

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApplication.shared.servicesProvider = services
            NSUpdateDynamicServices()
        }
    }

    /// macOS Services "Send URL with RequestPad": opens the selected URL as a new, unsaved request. Declared in
    /// Info.plist (`NSServices`, message `sendURL`).
    final class ServicesProvider: NSObject {
        /// Opens the result; tests replace it to observe what would be opened.
        var open: (RequestItem) -> Void = { request in
            Task { @MainActor in
                do {
                    let model = try await AppRuntime.shared.loadedModel()
                    AppRuntime.shared.show(.scratch(request), in: model)
                } catch {
                    Logger(subsystem: AppConstants.loggingSubsystem, category: "app")
                        .error("Services request not opened: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        @objc(sendURL:userData:error:)
        func sendURL(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)
        {
            guard let text = pasteboard.string(forType: .string), let url = SharedURL.url(from: text) else {
                error.pointee = String(localized: "The selection isn't a web address RequestPad can open.") as NSString
                return
            }
            open(RequestItem(name: SharedURL.requestName(for: url), url: url))
        }
    }
#endif
