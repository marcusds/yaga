import Foundation

/// Sources Yaga can search.
enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case giphy, klipy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .giphy: return "GIPHY"
        case .klipy: return "KLIPY"
        }
    }

    var keyURL: URL {
        switch self {
        case .giphy: return URL(string: "https://developers.giphy.com/dashboard/")!
        case .klipy: return URL(string: "https://partner.klipy.com/api-keys")!
        }
    }

    /// KLIPY requires this exact placeholder in the search field.
    var searchPlaceholder: String {
        switch self {
        case .giphy: return "Search GIPHY…"
        case .klipy: return "Search KLIPY"
        }
    }

    var attribution: String { "Powered by \(label)" }
}

enum GifError: LocalizedError {
    case missingKey(ProviderKind)
    case providerFailure(String)
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let kind):
            return "Add a \(kind.label) API key in Settings (⌘,) to search for GIFs."
        case .http(let code):
            let name = Settings.shared.provider.label
            switch code {
            case 401, 403: return "\(name) rejected the API key. Check it in Settings (⌘,)."
            case 429: return "\(name) rate limit reached. Test keys allow 100 calls an hour — try again shortly."
            default: return "\(name) request failed (HTTP \(code))."
            }
        case .providerFailure(let message):
            return message
        case .badResponse:
            return "Could not read the response from the GIF service."
        }
    }
}

/// Anything that can search for and list trending GIFs.
protocol GifProvider {
    func search(_ query: String, limit: Int) async throws -> [GifItem]
    func trending(limit: Int) async throws -> [GifItem]
}

enum Providers {
    static func make(_ kind: ProviderKind, key: String) -> GifProvider {
        switch kind {
        case .giphy: return GiphyProvider(key: key)
        case .klipy: return KlipyProvider(key: key)
        }
    }

    static func fetchJSON(_ url: URL) async throws -> [String: Any] {
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
}

// MARK: - GIPHY (v1)

struct GiphyProvider: GifProvider {
    let key: String

    func search(_ query: String, limit: Int) async throws -> [GifItem] {
        try await load(path: "search", extra: [URLQueryItem(name: "q", value: query)], limit: limit)
    }

    func trending(limit: Int) async throws -> [GifItem] {
        try await load(path: "trending", extra: [], limit: limit)
    }

    private func load(path: String, extra: [URLQueryItem], limit: Int) async throws -> [GifItem] {
        guard !key.isEmpty else { throw GifError.missingKey(.giphy) }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(path)")!
        components.queryItems = extra + [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "rating", value: Settings.shared.contentFilter.giphyValue),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ]
        let json = try await Providers.fetchJSON(components.url!)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap(Self.parse)
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

// MARK: - KLIPY

/// KLIPY's GIF API. The app key sits in the path rather than a query parameter,
/// and results arrive as `data.data[]` with a `file.<size>.<format>` tree.
struct KlipyProvider: GifProvider {
    let key: String

    func search(_ query: String, limit: Int) async throws -> [GifItem] {
        try await load(path: "search", extra: [URLQueryItem(name: "q", value: query)], limit: limit)
    }

    func trending(limit: Int) async throws -> [GifItem] {
        try await load(path: "trending", extra: [], limit: limit)
    }

    private func load(path: String, extra: [URLQueryItem], limit: Int) async throws -> [GifItem] {
        guard !key.isEmpty else { throw GifError.missingKey(.klipy) }
        var components = URLComponents(string: "https://api.klipy.com/api/v1/\(key)/gifs/\(path)")!
        components.queryItems = extra + [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "customer_id", value: Settings.shared.customerID),
            URLQueryItem(name: "content_filter", value: Settings.shared.contentFilter.klipyValue),
            URLQueryItem(name: "format_filter", value: "gif"),
        ]
        let json = try await Providers.fetchJSON(components.url!)
        // KLIPY reports failures in-band with a 200, so check `result` too.
        if let ok = json["result"] as? Bool, !ok {
            throw GifError.providerFailure((json["message"] as? String) ?? "KLIPY rejected the request.")
        }
        let page = json["data"] as? [String: Any] ?? [:]
        let items = page["data"] as? [[String: Any]] ?? []
        return items.compactMap(Self.parse)
    }

    private static func parse(_ result: [String: Any]) -> GifItem? {
        guard let slug = result["slug"] as? String,
              let file = result["file"] as? [String: Any]
        else { return nil }

        func gif(_ size: String) -> (URL, Int, Int)? {
            guard let bucket = file[size] as? [String: Any],
                  let entry = bucket["gif"] as? [String: Any],
                  let string = entry["url"] as? String,
                  let url = URL(string: string)
            else { return nil }
            return (url, entry["width"] as? Int ?? 0, entry["height"] as? Int ?? 0)
        }

        // `hd` runs to several megabytes; `md` is the sane full-size choice.
        guard let full = gif("md") ?? gif("hd") ?? gif("sm") else { return nil }
        let preview = gif("sm") ?? gif("xs") ?? full
        return GifItem(
            id: "klipy:\(slug)",
            title: result["title"] as? String ?? "GIF",
            previewURL: preview.0,
            gifURL: full.0,
            width: preview.1,
            height: preview.2,
            sourceURL: nil
        )
    }

    /// KLIPY asks integrations to report shares so its ranking can learn.
    /// Fire-and-forget: a failure here must never disturb a copy.
    static func registerShare(slug: String, key: String, customerID: String) {
        guard !key.isEmpty else { return }
        var components = URLComponents(string: "https://api.klipy.com/api/v1/\(key)/gifs/share/\(slug)")!
        components.queryItems = [URLQueryItem(name: "customer_id", value: customerID)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request).resume()
    }
}
