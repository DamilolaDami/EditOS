import Foundation

/// Talks to the GIPHY Stickers API. Returns transparent-background sticker
/// metadata for the library UI and caches downloads on disk so a clip can
/// reference them by local path after import.
actor GiphyService {
    struct Sticker: Identifiable, Sendable, Hashable {
        let id: String
        let title: String
        /// Small still preview suitable for grid rows.
        let previewURL: URL
        /// Full-quality animated GIF — what gets downloaded when the user
        /// places the sticker on the timeline.
        let originalURL: URL
        let nativeSize: CGSize?
    }

    enum ServiceError: Error {
        case missingAPIKey
        case badResponse
        case download
    }

    /// Optional so contributors can run the app without a GIPHY key.
    /// Callers should check `isConfigured` before showing the sticker
    /// panel; calls fail fast with `.missingAPIKey` otherwise.
    private let apiKey: String?
    private let session: URLSession

    var isConfigured: Bool { apiKey != nil }

    init(apiKey: String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Returns trending stickers when `query` is empty, otherwise a search.
    func search(query: String, limit: Int = 30) async throws -> [Sticker] {
        guard let apiKey else { throw ServiceError.missingAPIKey }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty
            ? "https://api.giphy.com/v1/stickers/trending"
            : "https://api.giphy.com/v1/stickers/search"
        var comps = URLComponents(string: base)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "rating", value: "g")
        ]
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { throw ServiceError.badResponse }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.data.compactMap { item -> Sticker? in
            // Prefer animated small for preview to feel like CapCut; fall back
            // to still if animated isn't there.
            let previewInfo = item.images.fixed_height_small
                ?? item.images.fixed_height_small_still
                ?? item.images.preview_gif
                ?? item.images.original
            guard
                let previewString = previewInfo?.url,
                let previewURL = URL(string: previewString),
                let originalString = item.images.original?.url,
                let originalURL = URL(string: originalString)
            else { return nil }
            let size: CGSize? = {
                guard
                    let widthString = item.images.original?.width,
                    let heightString = item.images.original?.height,
                    let widthValue = Double(widthString),
                    let heightValue = Double(heightString)
                else { return nil }
                return CGSize(width: widthValue, height: heightValue)
            }()
            return Sticker(
                id: item.id,
                title: item.title ?? "",
                previewURL: previewURL,
                originalURL: originalURL,
                nativeSize: size
            )
        }
    }

    /// Persistently downloads the sticker GIF into the app's Application
    /// Support directory and returns the local URL. Subsequent calls for the
    /// same sticker reuse the cached file.
    func download(_ sticker: Sticker) async throws -> URL {
        let destination = try stickerFileURL(for: sticker.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let (tempURL, response) = try await session.download(from: sticker.originalURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError.download
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func stickerFileURL(for id: String) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appending(path: "EditOS/Stickers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(id).gif")
    }
}

// MARK: - Wire format

private struct Response: Decodable {
    let data: [Item]

    struct Item: Decodable {
        let id: String
        let title: String?
        let images: Images
    }

    struct Images: Decodable {
        let original: ImageInfo?
        let fixed_height_small: ImageInfo?
        let fixed_height_small_still: ImageInfo?
        let preview_gif: ImageInfo?
    }

    struct ImageInfo: Decodable {
        let url: String
        let width: String?
        let height: String?
    }
}
