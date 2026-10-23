import Foundation

@main
private struct SettingsTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("popup-toggle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = PopupToggleSettings(url: directory.appendingPathComponent("nested/config.json"))
        precondition(settings.enabled, "Missing config must enable the popup")
        try settings.save(enabled: false)
        precondition(!settings.enabled, "False must disable the popup")
        try settings.save(enabled: true)
        precondition(settings.enabled, "True must enable the popup")
        for text in ["", "not JSON", "[]", "{}", "{\"enabled\":0}", "{\"enabled\":\"false\"}", "{\"enabled\":null}"] {
            try Data(text.utf8).write(to: settings.url)
            precondition(settings.enabled, "Invalid config must enable the popup: \(text)")
        }
        try Data("{\"enabled\":true,\"other\":{\"value\":42}}".utf8).write(to: settings.url)
        try settings.save(enabled: false)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings.url)) as! [String: Any]
        precondition((object["other"] as? [String: Int])?["value"] == 42, "Unrelated keys must survive")
        precondition(!settings.enabled)
        let blocked = PopupToggleSettings(url: settings.url.appendingPathComponent("config.json"))
        do {
            try blocked.save(enabled: false)
            preconditionFailure("Writing below a regular file must fail")
        } catch {}
        precondition(!settings.enabled, "Failed write must not change the original setting")
        print("PASS: tray settings tests")
    }
}
