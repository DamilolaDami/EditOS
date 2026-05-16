import Foundation
import Observation
import SwiftData

/// Top-level container for app services. Injected via `@Environment`.
/// Construct once at app launch; pass it down rather than spinning up
/// new service instances inside views.
@Observable
@MainActor
final class AppEnvironment {
    let projectStore: ProjectStore
    let mediaImporter: MediaImporter
    let thumbnailGenerator: ThumbnailGenerator
    let waveformGenerator: WaveformGenerator
    let assetResolver: BookmarkAssetResolver
    let giphyService: GiphyService
    let freesoundService: FreesoundService
    let exportEngine: ExportEngine
    let cloudKitSyncMonitor: CloudKitSyncMonitor
    let recentProjects: RecentProjects

    /// Container used to build the SwiftData-backed ProjectStore when one
    /// isn't supplied. Wired from `EditOSApp` at startup.
    init(
        modelContainer: ModelContainer,
        projectStore: ProjectStore? = nil,
        mediaImporter: MediaImporter = MediaImporter(),
        thumbnailGenerator: ThumbnailGenerator = ThumbnailGenerator(),
        waveformGenerator: WaveformGenerator = WaveformGenerator(),
        assetResolver: BookmarkAssetResolver = BookmarkAssetResolver(),
        giphyService: GiphyService? = nil,
        freesoundService: FreesoundService? = nil,
        exportEngine: ExportEngine = ExportEngine()
    ) {
        self.projectStore = projectStore ?? ProjectStore.live(container: modelContainer)
        self.mediaImporter = mediaImporter
        self.thumbnailGenerator = thumbnailGenerator
        self.waveformGenerator = waveformGenerator
        self.assetResolver = assetResolver
        // Built inline so the keys are pulled from `Secrets.plist` at
        // construction time. Each service falls back to a "not
        // configured" state when its key is absent, and the panels read
        // `isConfigured` to gate their UI.
        self.giphyService = giphyService ?? GiphyService(apiKey: APIKeys.giphy)
        self.freesoundService = freesoundService ?? FreesoundService(token: APIKeys.freesound)
        self.exportEngine = exportEngine
        // Built inline rather than as a default-parameter expression: the
        // monitor's init is `@MainActor`, so it can't be evaluated in the
        // caller's isolation context.
        self.cloudKitSyncMonitor = CloudKitSyncMonitor()
        self.recentProjects = RecentProjects()
    }
}
