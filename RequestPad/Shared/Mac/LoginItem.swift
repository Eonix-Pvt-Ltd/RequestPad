#if os(macOS)
    import Foundation
    import Observation
    import OSLog
    import RPCore
    import ServiceManagement

    /// Launch at login (X01.3, X02.2), behind a protocol so tests never change the user's login items.
    protocol LoginItemService {
        var status: SMAppService.Status { get }
        func register() throws
        func unregister() throws
        func openSystemSettings()
    }

    struct MainAppLoginItem: LoginItemService {
        var status: SMAppService.Status { SMAppService.mainApp.status }
        func register() throws { try SMAppService.mainApp.register() }
        func unregister() throws { try SMAppService.mainApp.unregister() }
        func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
    }

    /// The Settings toggle's state. The system's status is the source of truth (the user can change it in System
    /// Settings at any time), so it is re-read rather than stored.
    @Observable
    final class LoginItemModel {
        private(set) var status: SMAppService.Status
        private(set) var errorMessage: String?
        private let service: any LoginItemService
        private let log = Logger(subsystem: AppConstants.loggingSubsystem, category: "app")

        init(service: any LoginItemService = MainAppLoginItem()) {
            self.service = service
            status = service.status
        }

        /// On, or waiting for the user's approval in System Settings.
        var isEnabled: Bool { status == .enabled || status == .requiresApproval }
        var needsApproval: Bool { status == .requiresApproval }

        func setEnabled(_ enabled: Bool) {
            errorMessage = nil
            do {
                if enabled { try service.register() } else { try service.unregister() }
            } catch {
                log.error("Login item change failed: \(String(describing: type(of: error)), privacy: .public)")
                errorMessage =
                    enabled
                    ? String(
                        localized:
                            "RequestPad couldn't be added to your login items. Try again, or add it in System Settings › General › Login Items."
                    )
                    : String(
                        localized:
                            "RequestPad couldn't be removed from your login items. Remove it in System Settings › General › Login Items."
                    )
            }
            refresh()
        }

        func refresh() { status = service.status }

        func openSystemSettings() { service.openSystemSettings() }
    }
#endif
