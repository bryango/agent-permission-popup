import Foundation

enum ClaudeThreadTitleLookup {
    private static let maximumReadBytes = 1024 * 1024
    private static let maximumTitleCharacters = 512

    static func title(for sessionID: String, transcriptPath: String?) -> String? {
        guard !sessionID.isEmpty,
              let transcriptPath,
              !transcriptPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: transcriptPath) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            let readSize = min(fileSize, UInt64(maximumReadBytes))
            let startOffset = fileSize - readSize
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.read(upToCount: Int(readSize)),
                  data.count == Int(readSize) else {
                return nil
            }

            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteLine = startOffset == 0 ? 0 : 1
            let lastCompleteLine = data.last == 0x0A ? lines.count - 1 : lines.count - 2
            guard lastCompleteLine >= firstCompleteLine else {
                return nil
            }

            for index in stride(from: lastCompleteLine, through: firstCompleteLine, by: -1) {
                if let title = title(for: sessionID, in: lines[index]) {
                    return title
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func title(for sessionID: String, in line: Data.SubSequence) -> String? {
        guard !line.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              root["type"] as? String == "custom-title",
              root["sessionId"] as? String == sessionID,
              let rawTitle = root["customTitle"] as? String else {
            return nil
        }

        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }
        return String(title.prefix(maximumTitleCharacters))
    }
}

enum ClaudeThreadTitleTests {
    static func failures() -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeThreadTitleTests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["Could not create temporary fixtures: \(error)"]
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        var failures: [String] = []
        func fixture(_ name: String, _ contents: String) -> String? {
            let url = directory.appendingPathComponent(name)
            do {
                try Data(contents.utf8).write(to: url)
                return url.path
            } catch {
                failures.append("Could not write \(name): \(error)")
                return nil
            }
        }
        func expect(_ name: String, _ expected: String?, _ sessionID: String, _ path: String?) {
            let actual = ClaudeThreadTitleLookup.title(for: sessionID, transcriptPath: path)
            if actual != expected {
                failures.append("\(name): expected \(String(describing: expected)), got \(String(describing: actual))")
            }
        }

        let target = "target-session"
        let other = "other-session"
        let first = "{\"type\":\"custom-title\",\"sessionId\":\"\(target)\",\"customTitle\":\"First\"}\n"
        let latest = "{\"type\":\"custom-title\",\"sessionId\":\"\(target)\",\"customTitle\":\" Latest \\\"Title\\\" \"}\n"
        if let path = fixture("rename.jsonl", first + latest) {
            expect("latest rename wins", "Latest \"Title\"", target, path)
        }
        if let path = fixture("malformed-trailing.jsonl", first + "not json\n") {
            expect("malformed trailing record", "First", target, path)
        }
        if let path = fixture("incomplete-tail.jsonl", first + latest.dropLast()) {
            expect("incomplete trailing record", "First", target, path)
        }
        if let path = fixture("wrong-session.jsonl", "{\"type\":\"custom-title\",\"sessionId\":\"\(other)\",\"customTitle\":\"Wrong\"}\n") {
            expect("wrong session", nil, target, path)
        }
        if let path = fixture("unknown-type.jsonl", "{\"type\":\"assistant\",\"sessionId\":\"\(target)\",\"customTitle\":\"Wrong\"}\n") {
            expect("unknown metadata type", nil, target, path)
        }
        if let path = fixture("empty-title.jsonl", first + "{\"type\":\"custom-title\",\"sessionId\":\"\(target)\",\"customTitle\":\"  \\n\\t\"}\n") {
            expect("empty title", "First", target, path)
        }
        expect("missing path", nil, target, directory.appendingPathComponent("missing.jsonl").path)
        expect("empty session", nil, "", directory.appendingPathComponent("missing.jsonl").path)
        expect("empty path", nil, target, "")

        let longTitle = String(repeating: "x", count: 700)
        if let path = fixture("long-title.jsonl", "{\"type\":\"custom-title\",\"sessionId\":\"\(target)\",\"customTitle\":\"\(longTitle)\"}\n") {
            expect("long title", String(repeating: "x", count: 512), target, path)
        }

        let hugePrefix = String(repeating: "p", count: 1024 * 1024 + 128)
        if let path = fixture("bounded-prefix.jsonl", hugePrefix + "\n" + latest) {
            expect("line split at bounded scan boundary", "Latest \"Title\"", target, path)
        }
        if let path = fixture("old-title-outside-bound.jsonl", first + String(repeating: "q", count: 1024 * 1024 + 128)) {
            expect("bounded scan excludes old title", nil, target, path)
        }
        if let path = fixture("truncated-title.jsonl", "{\"type\":\"custom-title\",\"sessionId\":\"\(target)\",\"customTitle\":\"Truncated") {
            expect("truncated title record", nil, target, path)
        }
        return failures
    }
}
