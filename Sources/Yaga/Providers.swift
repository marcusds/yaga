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

    private static func parse(_ result: [String: Any]) -> GifItem? {
        guard let id = result["id"] as? String,
              let images = result["images"] as? [String: Any]
        else { return nil }

        func media(_ name: String) -> (URL, Int, Int)? {
            guard let entry = images[name] as? [String: Any],
                  let string = entry["url"] as? String,
                  let url = URL(string: string)
            else { return nil }
            return (url, Int(entry["width"] as? String ?? "") ?? 0, Int(entry["height"] as? String ?? "") ?? 0)
        }

        guard let full = media("downsized_medium") ?? media("fixed_width") ?? media("original") else { return nil }
        let preview = media("fixed_width") ?? media("fixed_width_downsampled") ?? full
        return GifItem(
            id: "giphy:\(id)",
            title: result["title"] as? String ?? "GIF",
            previewURL: preview.0,
            gifURL: full.0,
            width: preview.1,
            height: preview.2,
            sourceURL: (result["url"] as? String).flatMap(URL.init(string:))
        )
    }
}
