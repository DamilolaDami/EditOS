import Foundation
import OSLog

/// Resolves a `MediaAsset.bookmark` into a URL with an active security scope.
///
/// Each asset is resolved at most once per session — the resolved URL is cached
/// and held for the lifetime of the resolver. This avoids tearing down and
/// rebuilding the security scope every time we rebuild the composition, which
/// macOS sometimes refuses for the same underlying file.
actor BookmarkAssetResolver: AssetResolver {
    enum ResolveError: Error {
        case missingBookmark(MediaAsset.ID)
        case staleBookmark(MediaAsset.ID)
        case accessDenied(URL)
    }

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "BookmarkAssetResolver")

    private var cache: [MediaAsset.ID: URL] = [:]

    func resolve(_ asset: MediaAsset) async throws -> URL {
        if let cached = cache[asset.id] {
            return cached
        }

        guard let bookmark = asset.bookmark else {
            await Self.log.error("Asset \(asset.id, privacy: .public) has no bookmark")
            throw ResolveError.missingBookmark(asset.id)
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            await Self.log.error("Bookmark stale for \(asset.id, privacy: .public)")
            throw ResolveError.staleBookmark(asset.id)
        }
        guard url.startAccessingSecurityScopedResource() else {
            await Self.log.error("Access denied for \(url.path, privacy: .public)")
            throw ResolveError.accessDenied(url)
        }
        cache[asset.id] = url
        await Self.log.info("Resolved \(asset.displayName, privacy: .public) -> \(url.path, privacy: .public)")
        return url
    }

    deinit {
        for url in cache.values {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
