import Foundation
import OSLog
import RPCore
import RPData
import RPServices
import SwiftData

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The composition root (B3): every service the app uses, created once at launch and injected into models.
/// There are no other singletons.
final class AppEnvironment: Sendable {
    let locations: StorageLocations
    let store: LocalStore
    let secrets: any SecretStore
    let preferences: Preferences
    let folderAccess: any FolderAccess
    let authenticator: any UserAuthenticator
    let httpClient: any HTTPClient
    let transport: any HTTPTransport
    let oauth: OAuth2Service
    let schemaService: GraphQLSchemaService
    let echo: LocalEchoServer
    let metrics: MetricsSubscriber
    let isUITesting: Bool

    init(
        locations: StorageLocations, store: LocalStore, secrets: any SecretStore, preferences: Preferences,
        folderAccess: any FolderAccess,
        authenticator: any UserAuthenticator, httpClient: any HTTPClient, transport: any HTTPTransport,
        isUITesting: Bool
    ) {
        self.locations = locations
        self.store = store
        self.secrets = secrets
        self.preferences = preferences
        self.folderAccess = folderAccess
        self.authenticator = authenticator
        self.httpClient = httpClient
        self.transport = transport
        self.isUITesting = isUITesting
        oauth = OAuth2Service(
            transport: transport, secrets: secrets,
            authenticator: SystemWebAuthenticator(anchor: { AppEnvironment.presentationAnchor() }))
        schemaService = GraphQLSchemaService(transport: transport, cache: store)
        echo = LocalEchoServer()
        metrics = MetricsSubscriber(directory: locations.diagnosticsDirectory)
    }

    var executor: RequestExecutor {
        RequestExecutor(client: httpClient, secrets: secrets, oauth: oauth, history: store, cookies: store)
    }

    var runner: CollectionRunner { CollectionRunner(executor: executor) }

    var transfer: AppDataTransfer { AppDataTransfer(store: store) }

    var eraser: DataEraser {
        DataEraser(store: store, secrets: secrets, preferences: preferences, locations: locations)
    }

    var diagnostics: DiagnosticsService {
        DiagnosticsService(store: store, preferences: preferences, locations: locations)
    }

    /// Launch arguments understood in Debug builds only (UI tests): `-UITestMode` uses an in-memory store and a
    /// throwaway defaults suite so tests start clean and never touch real data.
    static var launchedForUITests: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-UITestMode")
        #else
            false
        #endif
    }

    /// Builds the live environment.
    static func live(locations: StorageLocations) throws(DataError) -> AppEnvironment {
        let uiTesting = launchedForUITests
        let container =
            uiTesting
            ? try PersistenceContainer.makeInMemory() : try PersistenceContainer.make(at: locations.databaseFile)
        let defaults: UserDefaults
        if uiTesting, let suite = UserDefaults(suiteName: "RequestPadUITests-\(UUID().uuidString)") {
            defaults = suite
        } else {
            defaults = .standard
        }
        let secrets: any SecretStore = uiTesting ? InMemorySecretStore() : KeychainStore()
        let authenticator: any UserAuthenticator = uiTesting ? FakeAuthenticator() : DeviceOwnerAuthenticator()
        return AppEnvironment(
            locations: locations, store: LocalStore(modelContainer: container), secrets: secrets,
            preferences: Preferences(defaults: defaults),
            folderAccess: SecurityScopedBookmarks(), authenticator: authenticator,
            httpClient: URLSessionHTTPClient(
                configuration: HTTPClientConfiguration(temporaryDirectory: locations.responseBodiesDirectory)),
            transport: URLSessionTransport(), isUITesting: uiTesting)
    }

    /// The window to present the OAuth sign-in sheet from.
    @MainActor
    static func presentationAnchor() -> ASPresentationAnchorType {
        #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let window = active?.keyWindow ?? active?.windows.first { return window }
            if let scene = active { return UIWindow(windowScene: scene) }
            return ASPresentationAnchorType()
        #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #endif
    }
}

#if os(iOS)
    typealias ASPresentationAnchorType = UIWindow
#else
    typealias ASPresentationAnchorType = NSWindow
#endif
