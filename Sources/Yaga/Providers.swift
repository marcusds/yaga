import Foundation

enum GifError: LocalizedError {
    case missingKey
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add a \(Giphy.label) API key in Settings (⌘,) to search for GIFs."
        case .http(let code):
            switch code {
            case 401, 403: return "\(Giphy.label) rejected the API key. Check it in Settings (⌘,)."
            case 429: return "\(Giphy.label) rate limit reached. Test keys allow 100 calls an hour — try again shortly."
            default: return "\(Giphy.label) request failed (HTTP \(code))."
            }
        case .badResponse:
            return "Couldn't read the response from \(Giphy.label)."
        }
    }
}

/// GIPHY's v1 API — the only source Yaga searches.
enum Giphy {
    static let label = "GIPHY"
    static let keyURL = URL(string: "https://developers.giphy.com/dashboard/")!
    static let searchPlaceholder = "Search GIPHY…"
    /// GIPHY's terms ask for visible attribution.
    static let attribution = "Powered by GIPHY"

    static func search(_ query: String, limit: Int) async throws -> [GifItem] {
        try await load(path: "search", extra: [URLQueryItem(name: "q", value: query)], limit: limit)
    }

    static func trending(limit: Int) async throws -> [GifItem] {
        try await load(path: "trending", extra: [], limit: limit)
    }

    private static func load(path: String, extra: [URLQueryItem], limit: Int) async throws -> [GifItem] {
        let key = Settings.shared.giphyKey
        guard !key.isEmpty else { throw GifError.missingKey }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)")!
        components.queryItems = extra + [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "rating", value: Settings.shared.contentFilter.giphyValue),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ]
        let json = try await fetchJSON(components.url!)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap(parse)
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GifError.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GifError.badResponse
        }
        return object
    }

    /// One GIPHY rendition.
    private struct Rendition {
        let url: URL
        let width: Int
        let height: Int
        let bytes: Int
    }

    /// Ceiling for the copied GIF, from Settings. The bytes are fetched before
    /// a paste fires and then held on the pasteboard, so the widest rendition
    /// is not worth having at any size.
    private static var maxCopyBytes: Int { Settings.shared.maxCopyMB * 1024 * 1024 }

    /// Internal rather than private so `--self-test` can drive it with a
    /// stubbed payload; nothing else outside this file calls it.
    static func parse(_ result: [String: Any]) -> GifItem? {
        guard let id = result["id"] as? String,
              let images = result["images"] as? [String: Any]
        else { return nil }

        func media(_ name: String) -> Rendition? {
            guard let entry = images[name] as? [String: Any],
                  let string = entry["url"] as? String,
                  let url = URL(string: string)
            else { return nil }
            return Rendition(
                url: url,
                width: Int(entry["width"] as? String ?? "") ?? 0,
                height: Int(entry["height"] as? String ?? "") ?? 0,
                bytes: Int(entry["size"] as? String ?? "") ?? 0
            )
        }

        // What gets copied decides how big the GIF looks in Slack and friends:
        // they render an upload at its own pixel width, so a 200px rendition
        // arrives as a postage stamp. Take the widest one that fits the byte
        // ceiling rather than a fixed name -- which rendition that is varies
        // per GIF, and `fixed_width` is only ever 200px across.
        let candidates = ["original", "downsized_large", "downsized_medium", "downsized", "fixed_width"]
            .compactMap(media)
            .filter { $0.width > 0 }
        let affordable = candidates.filter { $0.bytes == 0 || $0.bytes <= maxCopyBytes }
        // Every rendition over the ceiling: take the smallest rather than none.
        guard let full = affordable.max(by: { $0.width < $1.width })
                ?? candidates.min(by: { $0.bytes < $1.bytes })
                ?? media("original")
        else { return nil }

        // The grid wants the cheap one; it is only ever drawn a few hundred
        // points wide.
        let preview = media("fixed_width") ?? media("fixed_width_downsampled") ?? full
        return GifItem(
            id: "giphy:\(id)",
            title: result["title"] as? String ?? "GIF",
            previewURL: preview.url,
            gifURL: full.url,
            width: preview.width,
            height: preview.height,
            sourceURL: (result["url"] as? String).flatMap(URL.init(string:))
        )
    }
}
