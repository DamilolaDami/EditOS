import Foundation

/// Talks to the Freesound v2 REST API using token authentication. Returns
/// metadata + streamable preview URLs for the audio library, and caches HQ
/// MP3s into Application Support / EditOS / Freesound for offline reuse.
actor FreesoundService {
    struct Sound: Identifiable, Sendable, Hashable {
        let id: Int
        let name: String
        let username: String
        let duration: TimeInterval
        /// Streamable HQ MP3 — works for both preview playback and as the
        /// final downloaded asset.
        let previewURL: URL
        let license: String
    }

    enum ServiceError: Error {
        case badResponse
        case download
    }

    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Searches Freesound. Empty / blank `query` defaults to a popular "music"
    /// browse so the tab has something interesting before the user types.
    func search(query: String, limit: Int = 30) async throws -> [Sound] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents(string: "https://freesound.org/apiv2/search/text/")
        comps?.queryItems = [
            URLQueryItem(name: "query", value: trimmed.isEmpty ? "music" : trimmed),
            URLQueryItem(name: "page_size", value: "\(limit)"),
            URLQueryItem(name: "fields", value: "id,name,username,duration,previews,license"),
            // Skip super-short blips and giant ambient pieces.
            URLQueryItem(name: "filter", value: "duration:[2 TO 600]")
        ]
        guard let url = comps?.url else { throw ServiceError.badResponse }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.addValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.results.compactMap { item -> Sound? in
            let previewString = item.previews["preview-hq-mp3"]
                ?? item.previews["preview-lq-mp3"]
            guard let previewStringUnwrapped = previewString,
                  let previewURL = URL(string: previewStringUnwrapped) else {
                return nil
            }
            return Sound(
                id: item.id,
                name: item.name,
                username: item.username,
                duration: item.duration,
                previewURL: previewURL,
                license: item.license
            )
        }
    }

    /// Persistently downloads the HQ MP3 to Application Support / EditOS /
    /// Freesound / <id>.mp3 — subsequent calls for the same id reuse the
    /// cached file. `onProgress` fires on every body-bytes write with the
    /// fraction of expected bytes received (0…1) so callers can drive a UI
    /// progress ring without doing their own URLSession plumbing.
    func download(
        _ sound: Sound,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let destination = try soundFileURL(for: sound.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            onProgress(1.0)
            return destination
        }
        let request = URLRequest(url: sound.previewURL)
        let session = self.session

        // Modern URLSession.shared.download(for:delegate:) sometimes fails to
        // emit didWriteData for small MP3 files, leaving the UI stuck at 0.
        // Use a download task + NSProgress polling instead: URLSession updates
        // `task.progress.fractionCompleted` regardless of delegate, and a
        // 100 ms polling loop is plenty granular for the UI ring.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let pollHolder = PollHolder()
            let task = session.downloadTask(with: request) { tempURL, response, error in
                pollHolder.stop()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: ServiceError.download)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: ServiceError.download)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    onProgress(1.0)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            pollHolder.start(progress: task.progress, onProgress: onProgress)
            task.resume()
        }
    }

    private func soundFileURL(for id: Int) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appending(path: "EditOS/Freesound", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(id).mp3")
    }
}

// MARK: - Progress poller
//
// Holds the polling Task so it stays alive while the download runs, and
// exposes start/stop hooks for the continuation closure. `@unchecked Sendable`
// is fine: the underlying Foundation objects we touch (NSProgress,
// URLSessionTask) handle concurrent reads internally.

private final class PollHolder: @unchecked Sendable {
    private var pollTask: Task<Void, Never>?

    func start(progress: Progress, onProgress: @escaping @Sendable (Double) -> Void) {
        pollTask = Task.detached {
            // Initial tick so the UI flips from 0% the moment the task
            // resumes, even if the request hasn't yet returned any bytes.
            onProgress(progress.fractionCompleted)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }
                onProgress(progress.fractionCompleted)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Wire format

private struct SearchResponse: Decodable {
    let count: Int?
    let results: [Item]

    struct Item: Decodable {
        let id: Int
        let name: String
        let username: String
        let duration: Double
        let previews: [String: String]
        let license: String
    }
}
