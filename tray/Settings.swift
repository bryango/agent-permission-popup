import Foundation

struct PopupToggleSettings {
    let url: URL

    init(url: URL = Self.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["PERMISSION_POPUP_CONFIG"],
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/permission-popup/config.json")
    }

    private struct Value: Decodable {
        let enabled: Bool
    }

    var enabled: Bool {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return true
        }
        return value.enabled
    }

    func save(enabled: Bool) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["enabled"] = enabled
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
