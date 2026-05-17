import Foundation
import Observation
import OSLog

/// Watches the `~/Library/Application Support/EditOS/Recordings/`
/// directory and exposes a list of saved recordings to the Home view.
///
/// Recordings are grouped into pairs by proximity: a "Screen" .mov and
/// a "Camera" .mov whose creation timestamps differ by less than ~30s
/// are treated as one capture session (the screen+camera dual-recording
/// path). Solo files surface on their own.
@MainActor
@Observable
final class RecordingsLibrary {
    private(set) var entries: [Entry] = []

    private static let log = Logger(subsystem: "com.damioffice.EditOS", category: "RecordingsLibrary")

    /// One row in the Home page's Recent Recordings strip. Always
    /// carries a screen URL (the primary). `cameraURL` is populated
    /// when the recording session also captured the webcam.
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String  // path of the screen file (or solo camera)
        let screenURL: URL?
        let cameraURL: URL?
        let creationDate: Date
        let fileSize: Int64
        var displayName: String {
            (screenURL ?? cameraURL)?.deletingPathExtension().lastPathComponent ?? "Recording"
        }
        /// `true` when a paired camera clip is part of this session.
        var hasCamera: Bool { cameraURL != nil }
        /// `true` when this entry is a camera-only recording (no
        /// matching screen file found). Surfaced separately so the UI
        /// can label it accordingly.
        var isCameraOnly: Bool { screenURL == nil && cameraURL != nil }
        /// File the user opens when clicking the card. Screen takes
        /// priority; cam-only entries fall back to the camera file.
        var primaryURL: URL? { screenURL ?? cameraURL }
    }

    /// Re-scan the recordings folder. Cheap operation — single
    /// directory listing + sort. Call on view appearance and
    /// whenever a new recording finishes.
    func refresh() {
        guard let dir = Self.recordingsDirectory() else {
            entries = []
            return
        }

        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }

        // Bucket .mov files by Screen / Camera prefix. Anything else
        // gets skipped — the directory is owned by the recorder so
        // foreign files are unlikely, but be defensive.
        struct RawFile {
            let url: URL
            let date: Date
            let size: Int64
            let isScreen: Bool
        }
        var raw: [RawFile] = []
        for url in urls where url.pathExtension.lowercased() == "mov" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .creationDateKey])
            let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            let name = url.lastPathComponent
            let isScreen = name.hasPrefix("Screen ")
            let isCamera = name.hasPrefix("Camera ")
            guard isScreen || isCamera else { continue }
            raw.append(RawFile(url: url, date: date, size: size, isScreen: isScreen))
        }

        // Pair screens with cameras whose timestamps fall within
        // `pairingWindow` seconds — that's the dual-recording case.
        let pairingWindow: TimeInterval = 30
        let screens = raw.filter(\.isScreen).sorted { $0.date > $1.date }
        var cameras = raw.filter { !$0.isScreen }.sorted { $0.date > $1.date }

        var built: [Entry] = []
        for screen in screens {
            // Find the closest camera within the window. Greedy match —
            // each camera consumed exactly once. The recorder spins up
            // both within ~100ms so the closest one is always the right
            // pair when one exists.
            let camIdx = cameras.indices.min(by: {
                abs(cameras[$0].date.timeIntervalSince(screen.date)) <
                abs(cameras[$1].date.timeIntervalSince(screen.date))
            })
            let cam: RawFile? = {
                guard let idx = camIdx else { return nil }
                let candidate = cameras[idx]
                guard abs(candidate.date.timeIntervalSince(screen.date)) <= pairingWindow else { return nil }
                return cameras.remove(at: idx)
            }()
            built.append(Entry(
                id: screen.url.path,
                screenURL: screen.url,
                cameraURL: cam?.url,
                creationDate: screen.date,
                fileSize: screen.size + (cam?.size ?? 0)
            ))
        }
        // Any cameras left over (no matching screen) — show solo.
        for cam in cameras {
            built.append(Entry(
                id: cam.url.path,
                screenURL: nil,
                cameraURL: cam.url,
                creationDate: cam.date,
                fileSize: cam.size
            ))
        }
        entries = built.sorted { $0.creationDate > $1.creationDate }
    }

    /// Delete a recording from disk. The Home view calls this from a
    /// context-menu action so users can prune leftovers without
    /// hopping to Finder.
    func delete(_ entry: Entry) {
        let manager = FileManager.default
        for url in [entry.screenURL, entry.cameraURL].compactMap({ $0 }) {
            do {
                try manager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                Self.log.error("Failed to trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
    }

    /// Absolute path of the recordings folder, creating it on demand.
    /// Mirrors `ScreenRecorder.makeOutputURL()`'s convention so both
    /// services agree on where files live.
    static func recordingsDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appending(path: "EditOS/Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
