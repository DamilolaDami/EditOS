import Foundation
import Observation

/// Top-level container for app services. Injected via `@Environment`.
/// Construct once at app launch; pass it down rather than spinning up
/// new service instances inside views.
@Observable
@MainActor
final class AppEnvironment {
    let projectStore: ProjectStore
    let mediaImporter: MediaImporter
    let thumbnailGenerator: ThumbnailGenerator
    let assetResolver: BookmarkAssetResolver

    init(
        projectStore: ProjectStore? = nil,
        mediaImporter: MediaImporter = MediaImporter(),
        thumbnailGenerator: ThumbnailGenerator = ThumbnailGenerator(),
        assetResolver: BookmarkAssetResolver = BookmarkAssetResolver()
    ) {
        self.projectStore = projectStore ?? .live()
        self.mediaImporter = mediaImporter
        self.thumbnailGenerator = thumbnailGenerator
        self.assetResolver = assetResolver
    }
}
