import Foundation
import RPCore
import RPData
import RPServices
import RPStore

/// Collection runner (P06) and cookie jar (P07) operations.
extension AppModel {
    /// Requests of a collection or folder in tree order, with their folder inheritance chains.
    func runItems(collectionID: UUID, folderKey: String?) -> [RunItem] {
        guard let tree = collection(collectionID)?.tree else { return [] }
        return tree.requestsInOrder(under: folderKey).map { entry in
            RunItem(
                request: applyingDefaults(to: entry.request), folders: tree.folderChain(to: entry.folderKey),
                displayPath: tree.displayPath(of: entry.key))
        }
    }

    /// Runs `items` sequentially; the runner keeps extracted values between requests. History isn't recorded for runs.
    func run(_ items: [RunItem], collectionID: UUID, stopOnFailure: Bool) -> AsyncStream<RunEvent> {
        var context = sendContext(collectionID: collectionID, folderKey: nil)
        context.recordHistory = false
        return environment.runner.run(items, context: context, stopOnFailure: stopOnFailure)
    }

    func cookieJar() async -> CookieJar {
        do {
            return try await environment.store.cookieJar()
        } catch {
            present(error)
            return CookieJar()
        }
    }

    /// Removes cookies matching `shouldRemove` and returns the updated jar.
    func removeCookies(where shouldRemove: @Sendable (Cookie) -> Bool) async -> CookieJar {
        let jar = await cookieJar()
        let updated = CookieJar(cookies: jar.cookies.filter { !shouldRemove($0) })
        do {
            try await environment.store.saveCookieJar(updated)
        } catch {
            present(error)
        }
        return updated
    }
}
