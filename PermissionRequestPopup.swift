import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import SQLite3

private let maximumInputBytes = 8 * 1024 * 1024
private let defaultLifetime: TimeInterval = 540

private enum PopupSettings {
    private struct Configuration: Decodable {
        let enabled: Bool
    }

    static var isEnabled: Bool {
        let override = ProcessInfo.processInfo.environment["PERMISSION_POPUP_CONFIG"]
        let url: URL
        if let override, override.hasPrefix("/") {
            url = URL(fileURLWithPath: override)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/permission-popup/config.json")
        }
        // Only an explicit Boolean false disables the popup.
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return true
        }
        return config.enabled
    }
}

private func debugLog(_ message: String) {
    let environment = ProcessInfo.processInfo.environment
    guard (environment["PERMISSION_POPUP_DEBUG"]
        ?? environment["CODEX_PERMISSION_POPUP_DEBUG"]) == "1" else {
        return
    }
    FileHandle.standardError.write(Data("[codex-permission-popup] \(message)\n".utf8))
}

private enum PopupHost: String {
    case codex
    case claude
    case dsh

    // Return and the global key authorize only the handoff to Auto review.
    var continueDecision: HookDecision { self == .dsh ? .allow : .deferToHost }
    var authorizeDecision: HookDecision { self == .dsh ? .directAllow : .allow }
    var hasContinueButton: Bool { true }
    var allowButtonTitle: String {
        "Authorize  ⌃↩"
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .dsh: return "DSH"
        }
    }

    var hookEventName: String {
        switch self {
        case .codex: return "PermissionRequest"
        case .claude: return "PreToolUse"
        case .dsh: return "PermissionRequest"
        }
    }

    func shouldShow(_ request: HookRequest) -> Bool {
        switch self {
        case .codex:
            return ApprovalsReviewer.forTurn(
                request.turnID,
                inTranscriptAt: request.transcriptPath
            ) == .autoReview
        case .claude:
            return request.permissionMode == "auto"
                && ["Bash", "Edit", "Write"].contains(request.toolName)
        case .dsh:
            // The trusted Semi Auto caller chooses candidate coverage. Do not
            // filter tools, query Codex metadata, or reinterpret permission_mode.
            return true
        }
    }
}

private enum SourceLanguage: String {
    case shell
    case diff
    case json
    case text
}

private struct HookRequest {
    let sessionID: String
    let turnID: String
    let transcriptPath: String?
    let cwd: String
    let toolName: String
    let permissionMode: String?
    let reason: String?
    let source: String
    let language: SourceLanguage

    static func parse(_ data: Data, host: PopupHost = .codex) throws -> HookRequest {
        if host == .dsh { return try parseDSH(data) }
        guard data.count <= maximumInputBytes else {
            throw ParseError.inputTooLarge
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["hook_event_name"] as? String == host.hookEventName,
            let cwd = root["cwd"] as? String,
            let toolName = root["tool_name"] as? String
        else {
            throw ParseError.invalidPermissionRequest
        }

        let toolInput = root["tool_input"] ?? NSNull()
        let inputObject = toolInput as? [String: Any]
        if host == .claude, inputObject == nil {
            throw ParseError.invalidPermissionRequest
        }
        let command = inputObject?["command"] as? String
        let reason = (inputObject?["description"] as? String)
            ?? (inputObject?["justification"] as? String)

        let language: SourceLanguage
        let source: String
        switch (host, toolName) {
        case (.claude, "Bash"):
            language = command == nil ? .json : .shell
            source = command ?? Self.prettyJSON(toolInput)
        case (.claude, "Edit"):
            if let rendered = Self.claudeEditSource(inputObject ?? [:]) {
                language = .text
                source = rendered
            } else {
                language = .json
                source = Self.prettyJSON(toolInput)
            }
        case (.claude, "Write"):
            if let rendered = Self.claudeWriteSource(inputObject ?? [:]) {
                language = .text
                source = rendered
            } else {
                language = .json
                source = Self.prettyJSON(toolInput)
            }
        case (_, "Bash"):
            language = command == nil ? .json : .shell
            source = command ?? Self.prettyJSON(toolInput)
        case (_, "apply_patch"), (_, "Edit"), (_, "Write"):
            language = command == nil ? .json : .diff
            source = command ?? Self.prettyJSON(toolInput)
        default:
            language = JSONSerialization.isValidJSONObject(toolInput) ? .json : .text
            source = Self.prettyJSON(toolInput)
        }

        return HookRequest(
            sessionID: root["session_id"] as? String ?? "",
            turnID: root["turn_id"] as? String ?? "",
            transcriptPath: root["transcript_path"] as? String,
            cwd: cwd,
            toolName: toolName,
            permissionMode: root["permission_mode"] as? String,
            reason: reason,
            source: source,
            language: language
        )
    }

    private static func parseDSH(_ data: Data) throws -> HookRequest {
        guard data.count <= maximumInputBytes else { throw ParseError.inputTooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["hook_event_name"] as? String == "PermissionRequest",
              let cwd = root["cwd"] as? String,
              !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let toolName = root["tool_name"] as? String,
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let input = root["tool_input"] as? [String: Any] else {
            throw ParseError.invalidPermissionRequest
        }

        var source = Self.prettyJSON(input)
        var language = SourceLanguage.json
        switch toolName {
        case "Bash", "bash":
            // Never hide additional DSH arguments (e.g. requested sandbox
            // permissions) behind a command-only display.
            if let command = input["command"] as? String,
               Set(input.keys).isSubset(of: ["command", "description", "justification"]) {
                source = command
                language = .shell
            }
        case "Edit", "edit":
            if let rendered = Self.claudeEditSource(input) {
                source = rendered
                language = .text
            }
        case "Write", "write":
            if let rendered = Self.claudeWriteSource(input) {
                source = rendered
                language = .text
            }
        default:
            break
        }

        return HookRequest(
            sessionID: root["session_id"] as? String ?? "",
            turnID: "",
            transcriptPath: nil,
            cwd: cwd,
            toolName: toolName,
            permissionMode: root["permission_mode"] as? String,
            reason: (input["description"] as? String) ?? (input["justification"] as? String),
            source: source,
            language: language
        )
    }

    private static func claudeEditSource(_ input: [String: Any]) -> String? {
        guard let path = input["file_path"] as? String,
              let before = input["old_string"] as? String,
              let after = input["new_string"] as? String,
              input["replace_all"] == nil || input["replace_all"] is Bool,
              Set(input.keys).isSubset(of: ["file_path", "old_string", "new_string", "replace_all"])
        else { return nil }
        let replaceAll = input["replace_all"] as? Bool ?? false
        return "File: \(path)\nReplace all: \(replaceAll)\nBefore snippet:\n\(before)"
            + "\nAfter snippet:\n\(after)"
    }

    private static func claudeWriteSource(_ input: [String: Any]) -> String? {
        guard let path = input["file_path"] as? String,
              let content = input["content"] as? String,
              Set(input.keys).isSubset(of: ["file_path", "content"])
        else { return nil }
        return "File: \(path)\nContent:\n\(content)"
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            return String(describing: value)
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            return String(describing: value)
        }
    }

    enum ParseError: Error {
        case inputTooLarge
        case invalidPermissionRequest
    }
}

private enum ApprovalsReviewer: String {
    case user
    case autoReview = "auto_review"

    static func forTurn(_ turnID: String, inTranscriptAt path: String?) -> ApprovalsReviewer? {
        guard !turnID.isEmpty, let path, !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            var offset = try handle.seekToEnd()
            var suffix = Data()
            let chunkSize = 64 * 1024

            while offset > 0 {
                let count = min(chunkSize, Int(offset))
                offset -= UInt64(count)
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: count) else {
                    return nil
                }

                var combined = chunk
                combined.append(suffix)
                let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
                let firstCompleteLine = offset == 0 ? 0 : 1

                if lines.count > firstCompleteLine {
                    for index in stride(
                        from: lines.count - 1,
                        through: firstCompleteLine,
                        by: -1
                    ) {
                        if let reviewer = reviewer(forTurn: turnID, in: lines[index]) {
                            return reviewer
                        }
                    }
                }
                suffix = Data(lines[0])
            }
        } catch {
            debugLog("Could not read the session transcript: \(error)")
        }
        return nil
    }

    private static func reviewer(
        forTurn turnID: String,
        in line: Data.SubSequence
    ) -> ApprovalsReviewer? {
        guard
            let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            root["type"] as? String == "turn_context",
            let payload = root["payload"] as? [String: Any],
            payload["turn_id"] as? String == turnID,
            let rawValue = payload["approvals_reviewer"] as? String
        else {
            return nil
        }
        return ApprovalsReviewer(rawValue: rawValue)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum ThreadTitleLookup {
    static func title(for sessionID: String, transcriptPath: String?) -> String? {
        guard !sessionID.isEmpty else {
            return nil
        }
        return title(for: sessionID, codexHomeURL: codexHomeURL(transcriptPath: transcriptPath))
    }

    static func title(for sessionID: String, codexHomeURL: URL) -> String? {
        let indexURL = codexHomeURL.appendingPathComponent("session_index.jsonl")
        if let indexedTitle = indexedTitle(for: sessionID, indexURL: indexURL) {
            return indexedTitle
        }
        return title(
            for: sessionID,
            databaseURL: codexHomeURL.appendingPathComponent("state_5.sqlite")
        )
    }

    static func title(for sessionID: String, databaseURL: URL) -> String? {
        var databasePointer: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &databasePointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database = databasePointer else {
            if let databasePointer {
                sqlite3_close(databasePointer)
            }
            return nil
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 250)
        guard sqlite3_db_readonly(database, "main") == 1,
              sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            return nil
        }

        for column in ["name", "title"] {
            if let title = title(for: sessionID, column: column, database: database) {
                return title
            }
        }
        return nil
    }

    private static func title(
        for sessionID: String,
        column: String,
        database: OpaquePointer
    ) -> String? {
        guard column == "name" || column == "title" else {
            return nil
        }

        var statement: OpaquePointer?
        let query = "SELECT substr(\(column), 1, 512) FROM threads WHERE id = ?1 LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let titleBytes = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return normalizedTitle(String(cString: titleBytes))
    }

    private static func indexedTitle(for sessionID: String, indexURL: URL) -> String? {
        guard let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe) else {
            return nil
        }

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["id"] as? String == sessionID,
                let threadName = root["thread_name"] as? String
            else {
                continue
            }
            return normalizedTitle(threadName)
        }
        return nil
    }

    private static func normalizedTitle(_ value: String) -> String? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return nil
        }
        return String(title.prefix(512))
    }

    private static func codexHomeURL(transcriptPath: String?) -> URL {
        if let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !configuredHome.isEmpty {
            return URL(fileURLWithPath: configuredHome)
        }

        if let transcriptPath, !transcriptPath.isEmpty {
            var directory = URL(fileURLWithPath: transcriptPath).deletingLastPathComponent()
            while directory.path != "/" {
                if directory.lastPathComponent == "sessions"
                    || directory.lastPathComponent == "archived_sessions" {
                    return directory.deletingLastPathComponent()
                }
                directory = directory.deletingLastPathComponent()
            }
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }
}

private struct DisplayText {
    let value: String
    let revealedCharacterCount: Int

    static func revealingControls(in input: String) -> DisplayText {
        var output = ""
        output.reserveCapacity(input.count)
        var revealed = 0

        for scalar in input.unicodeScalars {
            let codePoint = scalar.value
            let isAllowedWhitespace = codePoint == 0x09 || codePoint == 0x0A
            let isControl = (codePoint < 0x20 || (0x7F...0x9F).contains(codePoint))
                && !isAllowedWhitespace
            let isDirectional = (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            let isZeroWidth = (0x200B...0x200F).contains(codePoint)
                || (0x2060...0x2064).contains(codePoint)
                || codePoint == 0xFEFF

            if isControl || isDirectional || isZeroWidth {
                output += String(format: "⟦U+%04X⟧", codePoint)
                revealed += 1
            } else {
                output.unicodeScalars.append(scalar)
            }
        }

        return DisplayText(value: output, revealedCharacterCount: revealed)
    }
}

private enum HookDecision {
    case allow
    case directAllow
    case deny
    case timeout
    case deferToHost

    var raisesHostWindow: Bool {
        switch self {
        case .deny, .timeout:
            return true
        case .allow, .directAllow, .deferToHost:
            return false
        }
    }

    var responseData: Data? {
        responseData(for: .codex)
    }

    func responseData(for host: PopupHost) -> Data? {
        // Defensive boundary: even an accidental abstention cannot let DSH
        // proceed without an explicit human allow.
        if host == .dsh, case .deferToHost = self {
            return HookDecision.deny.responseData(for: .dsh)
        }
        let decision: [String: Any]
        switch self {
        case .directAllow:
            // A distinct DSH-only value makes older callers fail closed instead
            // of silently treating direct approval as a review handoff.
            guard host == .dsh else { return nil }
            decision = ["behavior": "allow_direct"]
        case .allow:
            decision = ["behavior": "allow"]
        case .deny:
            decision = [
                "behavior": "deny",
                "message": "Denied from the native permission popup.",
            ]
        case .timeout:
            decision = [
                "behavior": "deny",
                "message": "Denied because the native permission request timed out before a "
                    + "decision was made. The user may be away; if permission requests time out "
                    + "repeatedly, pause the task and wait for the user to return.",
            ]
        case .deferToHost:
            return nil
        }

        let hookOutput: [String: Any]
        switch host {
        case .codex, .dsh:
            hookOutput = [
                "hookEventName": host.hookEventName,
                "decision": decision,
            ]
        case .claude:
            var output: [String: Any] = [
                "hookEventName": host.hookEventName,
                "permissionDecision": decision["behavior"] as? String ?? "deny",
            ]
            if let message = decision["message"] as? String {
                output["permissionDecisionReason"] = message
            }
            hookOutput = output
        }

        let response: [String: Any] = ["hookSpecificOutput": hookOutput]
        return try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }
}

private let popupTimeoutDecision = HookDecision.timeout

private enum DSHFailure {
    static func responseData(_ reason: String) -> Data {
        let output: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny", "message": reason],
        ]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
            ?? Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
    }

    static func emit(_ reason: String) {
        FileHandle.standardOutput.write(responseData(reason))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private func isCommandWDismissal(
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
) -> Bool {
    let relevantModifiers = modifierFlags.intersection([.command, .control, .option, .shift])
    return relevantModifiers == .command
        && charactersIgnoringModifiers?.lowercased() == "w"
}

private func isPlainContinueKey(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
) -> Bool {
    let relevantModifiers = modifierFlags.intersection([.command, .control, .option, .shift])
    return relevantModifiers.isEmpty
        && (keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter))
}

private func isLocalAuthorizeKey(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
) -> Bool {
    let relevantModifiers = modifierFlags.intersection([.command, .control, .option, .shift])
    return relevantModifiers == .control
        && (keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter))
}

private enum MainCodexApplication {
    static let bundleIdentifier = "com.openai.codex"
    static let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

    static func raiseWindow() {
        sendReopenRequest()

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard let application =
            applications.first(where: { $0.activationPolicy == .regular })
                ?? applications.first
        else {
            debugLog("Could not find the main Codex application to raise")
            return
        }

        let didUnhide = application.unhide()
        let didActivate = application.activate(options: [.activateAllWindows])
        if !didUnhide && !didActivate {
            debugLog("Could not unhide or activate the main Codex application")
        }
    }

    private static func sendReopenRequest() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [applicationURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                debugLog("LaunchServices reopen request failed")
            }
        } catch {
            debugLog("Could not send LaunchServices reopen request: \(error)")
        }
    }
}

private struct HotKeySpec {
    let modifiers: UInt32
    let keyCode: UInt32
    let displayName: String

    static let fallback = HotKeySpec(
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        keyCode: UInt32(kVK_Return),
        displayName: "⌃⌥⌘↩"
    )

    static func fromEnvironment() -> HotKeySpec {
        let environment = ProcessInfo.processInfo.environment
        guard
            let value = environment["PERMISSION_POPUP_HOTKEY"]
                ?? environment["CODEX_PERMISSION_HOTKEY"],
            !value.isEmpty
        else {
            return fallback
        }
        return parse(value) ?? fallback
    }

    static func parse(_ value: String) -> HotKeySpec? {
        let tokens = value
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var modifiers: UInt32 = 0
        var modifierGlyphs = ""
        var keyName: String?

        for token in tokens {
            switch token {
            case "control", "ctrl":
                modifiers |= UInt32(controlKey)
                if !modifierGlyphs.contains("⌃") {
                    modifierGlyphs += "⌃"
                }
            case "option", "alt":
                modifiers |= UInt32(optionKey)
                if !modifierGlyphs.contains("⌥") {
                    modifierGlyphs += "⌥"
                }
            case "shift":
                modifiers |= UInt32(shiftKey)
                if !modifierGlyphs.contains("⇧") {
                    modifierGlyphs += "⇧"
                }
            case "command", "cmd":
                modifiers |= UInt32(cmdKey)
                if !modifierGlyphs.contains("⌘") {
                    modifierGlyphs += "⌘"
                }
            default:
                guard keyName == nil else {
                    return nil
                }
                keyName = token
            }
        }

        guard
            modifiers != 0,
            let keyName,
            let key = keyTable[keyName]
        else {
            return nil
        }

        return HotKeySpec(
            modifiers: modifiers,
            keyCode: key.code,
            displayName: modifierGlyphs + key.glyph
        )
    }

    private static let keyTable: [String: (code: UInt32, glyph: String)] = [
        "a": (UInt32(kVK_ANSI_A), "A"),
        "b": (UInt32(kVK_ANSI_B), "B"),
        "c": (UInt32(kVK_ANSI_C), "C"),
        "d": (UInt32(kVK_ANSI_D), "D"),
        "e": (UInt32(kVK_ANSI_E), "E"),
        "f": (UInt32(kVK_ANSI_F), "F"),
        "g": (UInt32(kVK_ANSI_G), "G"),
        "h": (UInt32(kVK_ANSI_H), "H"),
        "i": (UInt32(kVK_ANSI_I), "I"),
        "j": (UInt32(kVK_ANSI_J), "J"),
        "k": (UInt32(kVK_ANSI_K), "K"),
        "l": (UInt32(kVK_ANSI_L), "L"),
        "m": (UInt32(kVK_ANSI_M), "M"),
        "n": (UInt32(kVK_ANSI_N), "N"),
        "o": (UInt32(kVK_ANSI_O), "O"),
        "p": (UInt32(kVK_ANSI_P), "P"),
        "q": (UInt32(kVK_ANSI_Q), "Q"),
        "r": (UInt32(kVK_ANSI_R), "R"),
        "s": (UInt32(kVK_ANSI_S), "S"),
        "t": (UInt32(kVK_ANSI_T), "T"),
        "u": (UInt32(kVK_ANSI_U), "U"),
        "v": (UInt32(kVK_ANSI_V), "V"),
        "w": (UInt32(kVK_ANSI_W), "W"),
        "x": (UInt32(kVK_ANSI_X), "X"),
        "y": (UInt32(kVK_ANSI_Y), "Y"),
        "z": (UInt32(kVK_ANSI_Z), "Z"),
        "return": (UInt32(kVK_Return), "↩"),
        "enter": (UInt32(kVK_Return), "↩"),
        "space": (UInt32(kVK_Space), "Space"),
    ]
}

private final class RequestQueueLock {
    private var descriptor: Int32 = -1

    init?() {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("codex-permission-popup.lock")
        descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return nil
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
    }

    func acquire(until deadline: Date) -> Bool {
        while Date() < deadline {
            if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
                return true
            }
            guard errno == EACCES || errno == EAGAIN else {
                return false
            }
            usleep(100_000)
        }
        return false
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = Darwin.close(descriptor)
        }
    }
}

private enum SyntaxHighlighter {
    private static let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let baseColor = NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.94, alpha: 1)
    static let backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.11, alpha: 1)

    static func highlight(_ source: String, as language: SourceLanguage) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.tabStops = stride(from: 28.0, through: 280.0, by: 28.0)
            .map { NSTextTab(textAlignment: .left, location: $0) }

        let output = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: baseFont,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraph,
            ]
        )

        switch language {
        case .shell:
            highlightShell(output)
        case .diff:
            highlightDiff(output)
        case .json:
            highlightJSON(output)
        case .text:
            break
        }
        return output
    }

    private static func highlightShell(_ output: NSMutableAttributedString) {
        apply(#"\b(if|then|else|elif|fi|for|in|do|done|case|esac|while|until|function)\b"#,
              color: NSColor(calibratedRed: 0.86, green: 0.52, blue: 0.96, alpha: 1),
              to: output)
        apply(#"(?<!\S)--?[A-Za-z0-9][A-Za-z0-9_-]*"#,
              color: NSColor(calibratedRed: 0.63, green: 0.78, blue: 1, alpha: 1),
              to: output)
        apply(#"(?:&&|\|\||>>|<<|[|&;<>])"#,
              color: NSColor(calibratedRed: 1, green: 0.48, blue: 0.68, alpha: 1),
              to: output)
        apply(#"'(?:[^']*)'|"(?:[^"\\]|\\.)*""#,
              color: NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.42, alpha: 1),
              to: output)
        apply(#"\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]"#,
              color: NSColor(calibratedRed: 0.42, green: 0.86, blue: 0.88, alpha: 1),
              to: output)
        apply(#"(?m)(?<!\S)#.*$"#,
              color: NSColor(calibratedRed: 0.48, green: 0.67, blue: 0.52, alpha: 1),
              to: output)
    }

    private static func highlightJSON(_ output: NSMutableAttributedString) {
        apply(#""(?:[^"\\]|\\.)*""#,
              color: NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.42, alpha: 1),
              to: output)
        apply(#""(?:[^"\\]|\\.)*"(?=\s*:)"#,
              color: NSColor(calibratedRed: 0.55, green: 0.76, blue: 1, alpha: 1),
              to: output)
        apply(#"(?<![A-Za-z0-9_])-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
              color: NSColor(calibratedRed: 0.72, green: 0.86, blue: 0.58, alpha: 1),
              to: output)
        apply(#"\b(true|false|null)\b"#,
              color: NSColor(calibratedRed: 0.86, green: 0.52, blue: 0.96, alpha: 1),
              to: output)
    }

    private static func highlightDiff(_ output: NSMutableAttributedString) {
        let text = output.string
        var offset = 0

        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let color: NSColor?
            if line.hasPrefix("@@") {
                color = NSColor(calibratedRed: 0.42, green: 0.86, blue: 0.88, alpha: 1)
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                color = NSColor(calibratedRed: 0.55, green: 0.86, blue: 0.58, alpha: 1)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                color = NSColor(calibratedRed: 1, green: 0.53, blue: 0.53, alpha: 1)
            } else if line.hasPrefix("***") || line.hasPrefix("---") || line.hasPrefix("+++") {
                color = NSColor(calibratedRed: 0.63, green: 0.78, blue: 1, alpha: 1)
            } else {
                color = nil
            }

            if let color, length > 0 {
                output.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: offset, length: length)
                )
            }
            offset += length + 1
        }
    }

    private static func apply(
        _ pattern: String,
        color: NSColor,
        to output: NSMutableAttributedString
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return
        }
        let range = NSRange(location: 0, length: (output.string as NSString).length)
        expression.enumerateMatches(in: output.string, range: range) { match, _, _ in
            guard let match else {
                return
            }
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

private let permissionHotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<PermissionWindowController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        controller.continueInHost(nil)
    }
    return noErr
}

private final class PermissionWindowController: NSObject, NSWindowDelegate, NSSoundDelegate {
    private let request: HookRequest
    private let host: PopupHost
    private let raiseHost: () -> Void
    private let displayThreadTitle: DisplayText?
    private let displayText: DisplayText
    private let displayCWD: DisplayText
    private let displayReason: DisplayText?
    private let hotKey: HotKeySpec
    private let deadline: Date

    private var window: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var timeoutTimer: Timer?
    private var appearanceSound: NSSound?
    private weak var shortcutStatus: NSTextField?
    private(set) var decision = HookDecision.deferToHost
    private var isFinished = false
    private var hotKeyRegistered = false

    init(request: HookRequest, threadTitle: String?, hotKey: HotKeySpec, deadline: Date,
         host: PopupHost, raiseHost: @escaping () -> Void) {
        self.request = request
        self.host = host
        self.raiseHost = raiseHost
        if host == .dsh { self.decision = .deny }
        let singleLineThreadTitle = threadTitle?
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        self.displayThreadTitle = singleLineThreadTitle.map(DisplayText.revealingControls)
        self.displayText = DisplayText.revealingControls(in: request.source)
        self.displayCWD = DisplayText.revealingControls(in: request.cwd)
        self.displayReason = request.reason.map(DisplayText.revealingControls)
        self.hotKey = hotKey
        self.deadline = deadline
    }

    func run() -> HookDecision {
        guard deadline.timeIntervalSinceNow > 0 else {
            raiseHost()
            return popupTimeoutDecision
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        buildWindow()
        registerLocalKeyMonitor()
        scheduleTimeout()

        // Building the window can consume the last of the deadline. Do not
        // enter a fresh event loop after finish() has already stopped it.
        if isFinished {
            cleanup()
            if decision.raisesHostWindow { raiseHost() }
            return decision
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        registerGlobalHotKey()
        updateShortcutStatus()
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.playAppearanceSound()
        }
        app.run()

        cleanup()
        app.deactivate()
        if decision.raisesHostWindow {
            raiseHost()
        }
        return decision
    }

    private func playAppearanceSound() {
        guard !isFinished, window?.isVisible == true else { return }
        guard let sound = NSSound(
            contentsOfFile: "/System/Library/Sounds/Glass.aiff",
            byReference: false
        ) else {
            debugLog("Appearance sound could not be loaded")
            return
        }
        appearanceSound = sound
        sound.delegate = self
        debugLog("Appearance sound playback started: \(sound.play())")
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        debugLog("Appearance sound playback finished: \(finishedPlaying)")
    }

    @objc func authorize(_ sender: Any?) {
        finish(with: host.authorizeDecision)
    }

    @objc private func deny(_ sender: Any?) {
        finish(with: .deny)
    }

    @objc func continueInHost(_ sender: Any?) {
        finish(with: host.continueDecision)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(with: .deny)
        return false
    }

    private func finish(with decision: HookDecision) {
        guard !isFinished else {
            return
        }
        isFinished = true
        self.decision = decision
        timeoutTimer?.invalidate()
        window?.orderOut(nil)
        NSApp.stop(nil)

        if let wakeEvent = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApp.postEvent(wakeEvent, atStart: false)
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Permission Request"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 460)
        window.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(
            wrappingLabelWithString: displayThreadTitle?.value
                ?? "\(request.toolName) requests permission"
        )
        title.font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.cell?.usesSingleLineMode = false
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = displayThreadTitle?.value

        let location = NSTextField(labelWithString: displayCWD.value)
        location.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        location.toolTip = displayCWD.value

        let reasonValue = displayReason?.value ?? ""
        let reason = NSTextField(wrappingLabelWithString: reasonValue.isEmpty
            ? "Review the exact request before authorizing it."
            : reasonValue)
        reason.font = NSFont.systemFont(ofSize: 16)
        reason.maximumNumberOfLines = 3

        let revealedCharacterCount = displayText.revealedCharacterCount
            + (displayThreadTitle?.revealedCharacterCount ?? 0)
            + displayCWD.revealedCharacterCount
            + (displayReason?.revealedCharacterCount ?? 0)
        let integrityMessage: String
        if revealedCharacterCount == 0 {
            integrityMessage = "Exact content • syntax highlighted • soft-wrapped"
        } else {
            integrityMessage =
                "Warning: \(revealedCharacterCount) hidden or control "
                + "character(s) are shown as ⟦U+XXXX⟧"
        }
        let integrity = NSTextField(labelWithString: integrityMessage)
        integrity.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        integrity.textColor = revealedCharacterCount == 0
            ? .secondaryLabelColor
            : .systemOrange
        integrity.isHidden = revealedCharacterCount == 0

        let scrollView = makeSourceView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let shortcutStatus = NSTextField(labelWithString: "Registering global shortcut…")
        shortcutStatus.font = NSFont.systemFont(ofSize: 14)
        shortcutStatus.textColor = .secondaryLabelColor
        shortcutStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.shortcutStatus = shortcutStatus

        let denyButton = NSButton(
            title: "Deny  Esc",
            target: self,
            action: #selector(deny(_:))
        )
        denyButton.bezelStyle = .rounded
        denyButton.font = NSFont.systemFont(ofSize: 14)
        denyButton.keyEquivalent = "\u{1b}"

        let deferButton = NSButton(
            title: "Auto review  ↩ / \(hotKey.displayName)",
            target: self,
            action: #selector(continueInHost(_:))
        )
        deferButton.bezelStyle = .rounded
        deferButton.font = NSFont.systemFont(ofSize: 14)
        deferButton.keyEquivalent = "\r"
        deferButton.keyEquivalentModifierMask = []

        let allowButton = NSButton(
            title: host.allowButtonTitle,
            target: self,
            action: #selector(authorize(_:))
        )
        allowButton.bezelStyle = .rounded
        allowButton.font = NSFont.systemFont(ofSize: 14)
        allowButton.hasDestructiveAction = false
        allowButton.keyEquivalent = "\r"
        allowButton.keyEquivalentModifierMask = [.control]

        let buttons = host.hasContinueButton
            ? [denyButton, deferButton, allowButton] : [denyButton, allowButton]
        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let footer = NSStackView(views: [shortcutStatus, buttonStack])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.distribution = .fill
        buttonStack.distribution = .fill
        buttonStack.setContentHuggingPriority(.required, for: .horizontal)
        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: footerRow.leadingAnchor),
            footer.topAnchor.constraint(equalTo: footerRow.topAnchor),
            footer.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor),
        ])

        root.addArrangedSubview(title)
        root.addArrangedSubview(location)
        root.addArrangedSubview(reason)
        root.addArrangedSubview(integrity)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(footerRow)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        guard let contentView = window.contentView else {
            return
        }

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            title.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            location.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            reason.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            integrity.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            footerRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
        ])

        self.window = window
    }

    private func updateShortcutStatus() {
        shortcutStatus?.stringValue = hotKeyRegistered
            ? "Auto review globally with \(hotKey.displayName)"
            : "Global shortcut unavailable; use Auto review."
    }

    private func registerLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if isCommandWDismissal(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
            ) {
                self?.finish(with: .deny)
                return nil
            }
            if isLocalAuthorizeKey(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) {
                if let self { self.finish(with: self.host.authorizeDecision) }
                return nil
            }
            if isPlainContinueKey(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) {
                self?.continueInHost(nil)
                return nil
            }
            return event
        }
    }

    private func makeSourceView() -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = SyntaxHighlighter.backgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textStorage?.setAttributedString(
            SyntaxHighlighter.highlight(displayText.value, as: request.language)
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            permissionHotKeyHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            debugLog("InstallEventHandler failed with status \(handlerStatus)")
            return
        }

        let identifier = EventHotKeyID(signature: 0x4344_5841, id: 1) // CDXA
        let registrationStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        hotKeyRegistered = registrationStatus == noErr
        if !hotKeyRegistered {
            debugLog("RegisterEventHotKey failed with status \(registrationStatus)")
        }
    }

    private func scheduleTimeout() {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            finish(with: popupTimeoutDecision)
            return
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) {
            [weak self] _ in
            self?.finish(with: popupTimeoutDecision)
        }
    }

    private func cleanup() {
        timeoutTimer?.invalidate()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

private enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func claudeFixture(
            event: String = "PreToolUse",
            mode: String? = "auto",
            tool: String = "Bash",
            input: [String: Any] = ["command": "printf safe"]
        ) -> Data {
            var root: [String: Any] = [
                "hook_event_name": event,
                "session_id": "claude-session",
                "transcript_path": "/tmp/claude.jsonl",
                "cwd": "/tmp/example",
                "tool_name": tool,
                "tool_input": input,
            ]
            if let mode {
                root["permission_mode"] = mode
            }
            return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
        }

        for (mode, expected) in [
            ("auto", true),
            ("default", false),
            ("auto", true),
            ("plan", false),
            ("bypassPermissions", false),
            ("acceptEdits", false),
            ("dontAsk", false),
            ("unknown", false),
        ] {
            do {
                let request = try HookRequest.parse(claudeFixture(mode: mode), host: .claude)
                expect(
                    PopupHost.claude.shouldShow(request) == expected,
                    "Claude \(mode) eligibility",
                    into: &failures
                )
            } catch {
                failures.append("Claude \(mode) parsing threw \(error)")
            }
        }

        do {
            let request = try HookRequest.parse(claudeFixture(mode: nil), host: .claude)
            expect(!PopupHost.claude.shouldShow(request), "Claude missing mode", into: &failures)
        } catch {
            failures.append("Claude missing-mode parsing threw \(error)")
        }

        do {
            let command = "printf '%s\\n' \"$CLAUDE_EXACT\""
            let request = try HookRequest.parse(
                claudeFixture(input: ["command": command]),
                host: .claude
            )
            expect(request.source == command, "Claude Bash exact command", into: &failures)
        } catch {
            failures.append("Claude Bash parsing threw \(error)")
        }

        do {
            let request = try HookRequest.parse(
                claudeFixture(mode: "auto", tool: "WebFetch"),
                host: .claude
            )
            expect(!PopupHost.claude.shouldShow(request), "Claude unknown tool", into: &failures)
        } catch {
            failures.append("Claude unknown-tool parsing threw \(error)")
        }

        do {
            _ = try HookRequest.parse(
                claudeFixture(event: "PermissionRequest"),
                host: .claude
            )
            failures.append("Claude event mismatch accepted")
        } catch {}

        do {
            let edit = try HookRequest.parse(
                claudeFixture(tool: "Edit", input: [
                    "file_path": "/tmp/example.swift",
                    "old_string": "before text",
                    "new_string": "after text",
                    "replace_all": true,
                ]),
                host: .claude
            )
            expect(edit.language == .text, "Claude Edit language", into: &failures)
            expect(edit.source.contains("File: /tmp/example.swift"), "Claude Edit path", into: &failures)
            expect(edit.source.contains("Replace all: true"), "Claude Edit replace-all", into: &failures)
            expect(
                edit.source.contains("Before snippet:\nbefore text"),
                "Claude Edit before",
                into: &failures
            )
            expect(
                edit.source.contains("After snippet:\nafter text"),
                "Claude Edit after",
                into: &failures
            )

            let writeContent = "first line\n--- not a fabricated diff\nlast line"
            let write = try HookRequest.parse(
                claudeFixture(tool: "Write", input: [
                    "file_path": "/tmp/output.txt",
                    "content": writeContent,
                ]),
                host: .claude
            )
            expect(write.language == .text, "Claude Write language", into: &failures)
            expect(write.source.contains("File: /tmp/output.txt"), "Claude Write path", into: &failures)
            expect(write.source.hasSuffix(writeContent), "Claude Write full content", into: &failures)
        } catch {
            failures.append("Claude Edit/Write parsing threw \(error)")
        }

        do {
            for tool in ["Edit", "Write"] {
                let malformed = try HookRequest.parse(
                    claudeFixture(tool: tool, input: ["content": 42, "extra_field": "preserved"]),
                    host: .claude)
                expect(malformed.language == .json && malformed.source.contains("extra_field"),
                       "Claude malformed \(tool) retains full JSON", into: &failures)
            }
            let controls = "hello\u{202E}world"
            let request = try HookRequest.parse(claudeFixture(tool: "Write", input: [
                "file_path": "/tmp/file", "content": controls,
            ]), host: .claude)
            expect(DisplayText.revealingControls(in: request.source).revealedCharacterCount == 1,
                   "Claude rendered content reveals control characters", into: &failures)
        } catch {
            failures.append("Claude fallback display tests threw \(error)")
        }

        let timeoutMessage = "Denied because the native permission request timed out before a "
            + "decision was made. The user may be away; if permission requests time out "
            + "repeatedly, pause the task and wait for the user to return."
        for (decision, behavior, name) in [
            (HookDecision.allow, "allow", "allow"),
            (HookDecision.deny, "deny", "deny"),
            (HookDecision.timeout, "deny", "timeout"),
        ] {
            if let response = decision.responseData(for: .claude),
               let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
               let output = root["hookSpecificOutput"] as? [String: Any] {
                expect(
                    output["hookEventName"] as? String == "PreToolUse",
                    "Claude \(name) event",
                    into: &failures
                )
                expect(
                    output["permissionDecision"] as? String == behavior,
                    "Claude \(name) response",
                    into: &failures
                )
                expect(output["decision"] == nil && output["updatedInput"] == nil
                    && output["updatedPermissions"] == nil,
                    "Claude response neither nests Codex decision nor changes inputs/rules",
                    into: &failures)
                if name == "timeout" {
                    expect(
                        output["permissionDecisionReason"] as? String == timeoutMessage,
                        "Claude timeout response message",
                        into: &failures
                    )
                } else if name == "deny" {
                    expect(
                        output["permissionDecisionReason"] as? String
                            == "Denied from the native permission popup.",
                        "Claude deny response message",
                        into: &failures
                    )
                }
            } else {
                failures.append("Claude \(name) response serialization")
            }
        }
        expect(
            HookDecision.deferToHost.responseData(for: .claude) == nil,
            "Claude Continue response",
            into: &failures
        )

        let fixture = """
        {
          "hook_event_name": "PermissionRequest",
          "session_id": "session-1",
          "turn_id": "turn-1",
          "cwd": "/tmp/example",
          "tool_name": "Bash",
          "tool_input": {
            "command": "printf '%s\\\\n' \\"$VALUE\\" && echo done",
            "description": "Run the example"
          }
        }
        """

        do {
            let request = try HookRequest.parse(Data(fixture.utf8))
            expect(request.toolName == "Bash", "Bash tool name", into: &failures)
            expect(request.language == .shell, "shell language", into: &failures)
            expect(request.reason == "Run the example", "description parsing", into: &failures)
            expect(request.source.contains("$VALUE"), "command parsing", into: &failures)
        } catch {
            failures.append("request parsing threw \(error)")
        }

        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-permission-popup-\(UUID().uuidString).jsonl")
        let transcript = """
        {"type":"turn_context","payload":{"turn_id":"turn-auto","approvals_reviewer":"auto_review"}}
        {"type":"response_item","payload":{"turn_id":"turn-user","approvals_reviewer":"auto_review"}}
        {"type":"turn_context","payload":{"turn_id":"turn-user","approvals_reviewer":"user"}}
        """
        do {
            try Data(transcript.utf8).write(to: transcriptURL, options: .atomic)
            expect(
                ApprovalsReviewer.forTurn(
                    "turn-auto",
                    inTranscriptAt: transcriptURL.path
                ) == .autoReview,
                "auto-review turn detection",
                into: &failures
            )
            expect(
                ApprovalsReviewer.forTurn(
                    "turn-user",
                    inTranscriptAt: transcriptURL.path
                ) == .user,
                "user-review turn detection",
                into: &failures
            )
            expect(
                ApprovalsReviewer.forTurn(
                    "turn-missing",
                    inTranscriptAt: transcriptURL.path
                ) == nil,
                "unknown reviewer detection",
                into: &failures
            )
            try FileManager.default.removeItem(at: transcriptURL)
        } catch {
            failures.append("reviewer transcript fixture threw \(error)")
            try? FileManager.default.removeItem(at: transcriptURL)
        }

        let stateFixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-permission-popup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: stateFixtureDirectory,
            withIntermediateDirectories: false
        )
        let stateDatabaseURL = stateFixtureDirectory.appendingPathComponent("state_5.sqlite")
        var stateDatabase: OpaquePointer?
        let stateOpenResult = sqlite3_open(stateDatabaseURL.path, &stateDatabase)
        if stateOpenResult == SQLITE_OK, let stateDatabase {
            let setupResult = sqlite3_exec(
                stateDatabase,
                """
                CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL);
                INSERT INTO threads VALUES ('session-1', 'Permission popup thread');
                """,
                nil,
                nil,
                nil
            )
            sqlite3_close(stateDatabase)
            expect(setupResult == SQLITE_OK, "thread title fixture setup", into: &failures)
            expect(
                ThreadTitleLookup.title(
                    for: "session-1",
                    databaseURL: stateDatabaseURL
                ) == "Permission popup thread",
                "thread title lookup",
                into: &failures
            )

            var namedStateDatabase: OpaquePointer?
            let addNameResult = sqlite3_open(stateDatabaseURL.path, &namedStateDatabase)
            if addNameResult == SQLITE_OK, let namedStateDatabase {
                sqlite3_exec(
                    namedStateDatabase,
                    """
                    ALTER TABLE threads ADD COLUMN name TEXT;
                    UPDATE threads SET name = 'Database concise name' WHERE id = 'session-1';
                    """,
                    nil,
                    nil,
                    nil
                )
                sqlite3_close(namedStateDatabase)
                expect(
                    ThreadTitleLookup.title(
                        for: "session-1",
                        databaseURL: stateDatabaseURL
                    ) == "Database concise name",
                    "database name precedence",
                    into: &failures
                )
            } else {
                if let namedStateDatabase {
                    sqlite3_close(namedStateDatabase)
                }
                failures.append("database name fixture open")
            }

            let sessionIndexURL = stateFixtureDirectory
                .appendingPathComponent("session_index.jsonl")
            let sessionIndex = """
            {"id":"session-1","thread_name":"Concise thread title","updated_at":"test"}
            """
            do {
                try Data(sessionIndex.utf8).write(to: sessionIndexURL, options: .atomic)
                expect(
                    ThreadTitleLookup.title(
                        for: "session-1",
                        codexHomeURL: stateFixtureDirectory
                    ) == "Concise thread title",
                    "session index title precedence",
                    into: &failures
                )
            } catch {
                failures.append("session index fixture threw \(error)")
            }
        } else {
            if let stateDatabase {
                sqlite3_close(stateDatabase)
            }
            failures.append("thread title fixture open")
        }

        var changedSchemaDatabase: OpaquePointer?
        if sqlite3_open(stateDatabaseURL.path, &changedSchemaDatabase) == SQLITE_OK,
           let changedSchemaDatabase {
            sqlite3_exec(changedSchemaDatabase, "DROP TABLE threads", nil, nil, nil)
            sqlite3_close(changedSchemaDatabase)
            expect(
                ThreadTitleLookup.title(
                    for: "session-1",
                    databaseURL: stateDatabaseURL
                ) == nil,
                "thread title schema-change fallback",
                into: &failures
            )
        } else {
            if let changedSchemaDatabase {
                sqlite3_close(changedSchemaDatabase)
            }
            failures.append("thread title schema-change fixture")
        }
        try? FileManager.default.removeItem(at: stateFixtureDirectory)

        let revealed = DisplayText.revealingControls(in: "safe\u{202E}text")
        expect(revealed.revealedCharacterCount == 1, "control count", into: &failures)
        expect(revealed.value == "safe⟦U+202E⟧text", "control rendering", into: &failures)

        expect(
            HotKeySpec.parse("control+option+command+return")?.displayName == "⌃⌥⌘↩",
            "hotkey parsing",
            into: &failures
        )
        expect(
            HotKeySpec.fallback.modifiers == UInt32(controlKey | optionKey | cmdKey)
                && HotKeySpec.fallback.keyCode == UInt32(kVK_Return),
            "default global shortcut is four-key Continue",
            into: &failures
        )
        expect(
            isCommandWDismissal(
                charactersIgnoringModifiers: "w",
                modifierFlags: [.command]
            ),
            "Command-W dismissal",
            into: &failures
        )
        expect(
            !isCommandWDismissal(
                charactersIgnoringModifiers: "w",
                modifierFlags: [.command, .shift]
            ),
            "modified Command-W is not dismissal",
            into: &failures
        )
        expect(
            isPlainContinueKey(
                keyCode: UInt16(kVK_Return),
                modifierFlags: []
            ),
            "plain Return continues",
            into: &failures
        )
        expect(
            isPlainContinueKey(
                keyCode: UInt16(kVK_ANSI_KeypadEnter),
                modifierFlags: []
            ),
            "plain keypad Enter continues",
            into: &failures
        )
        expect(
            !isPlainContinueKey(
                keyCode: UInt16(kVK_Return),
                modifierFlags: [.command]
            ),
            "modified Return is not local continue",
            into: &failures
        )
        expect(
            isLocalAuthorizeKey(
                keyCode: UInt16(kVK_Return),
                modifierFlags: [.control]
            ),
            "Control-Return authorizes locally",
            into: &failures
        )
        expect(
            isLocalAuthorizeKey(
                keyCode: UInt16(kVK_ANSI_KeypadEnter),
                modifierFlags: [.control]
            ),
            "Control-keypad-Enter authorizes locally",
            into: &failures
        )
        expect(
            !isLocalAuthorizeKey(
                keyCode: UInt16(kVK_Return),
                modifierFlags: [.control, .option, .command]
            ),
            "global shortcut does not authorize",
            into: &failures
        )

        if let response = HookDecision.allow.responseData,
           let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let hookOutput = root["hookSpecificOutput"] as? [String: Any],
           let decision = hookOutput["decision"] as? [String: Any] {
            expect(decision["behavior"] as? String == "allow", "allow response", into: &failures)
        } else {
            failures.append("allow response serialization")
        }

        if let response = HookDecision.deny.responseData,
           let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let hookOutput = root["hookSpecificOutput"] as? [String: Any],
           let decision = hookOutput["decision"] as? [String: Any] {
            expect(decision["behavior"] as? String == "deny", "deny response", into: &failures)
            expect(HookDecision.deny.raisesHostWindow, "deny raises Codex", into: &failures)
        } else {
            failures.append("deny response serialization")
        }

        expect(
            HookDecision.deferToHost.responseData == nil,
            "global shortcut defer response",
            into: &failures
        )
        if let response = popupTimeoutDecision.responseData,
           let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let hookOutput = root["hookSpecificOutput"] as? [String: Any],
           let decision = hookOutput["decision"] as? [String: Any] {
            expect(decision["behavior"] as? String == "deny", "timeout denies", into: &failures)
            expect(
                decision["message"] as? String == "Denied because the native permission request "
                    + "timed out before a decision was made. The user may be away; if permission "
                    + "requests time out repeatedly, pause the task and wait for the user to return.",
                "timeout response message",
                into: &failures
            )
            expect(
                popupTimeoutDecision.raisesHostWindow,
                "timeout raises Codex",
                into: &failures
            )
        } else {
            failures.append("timeout response serialization")
        }

        failures += ClaudeThreadTitleTests.failures()
        failures += ClaudeHostApplicationTests.failures()
        expect(PopupOptions.parse([])?.host == .codex, "default host unchanged", into: &failures)
        expect(PopupOptions.parse(["--host", "claude"])?.host == .claude,
               "explicit Claude host", into: &failures)
        expect(PopupOptions.parse(["--host", "unknown"]) == nil,
               "unknown host rejected", into: &failures)
        expect(PopupOptions.parse(["--host", "claude", "--host", "codex"]) == nil,
               "duplicate host rejected", into: &failures)

        if failures.isEmpty {
            print("PASS: permission popup self-test")
            return true
        }

        for failure in failures {
            FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
        }
        return false
    }

    private static func expect(_ condition: Bool, _ name: String, into failures: inout [String]) {
        if !condition {
            failures.append(name)
        }
    }
}

private struct PopupOptions {
    let host: PopupHost
    let selfTest: Bool

    static func parse(_ arguments: [String]) -> PopupOptions? {
        var host = PopupHost.codex
        var seenHost = false
        var selfTest = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--host":
                guard !seenHost, index + 1 < arguments.count,
                      let value = PopupHost(rawValue: arguments[index + 1]) else { return nil }
                host = value
                seenHost = true
                index += 2
            case "--self-test":
                guard !selfTest else { return nil }
                selfTest = true
                index += 1
            default:
                return nil
            }
        }
        return PopupOptions(host: host, selfTest: selfTest)
    }
}

@main
private struct PermissionPopupMain {
    static func main() {
        guard let options = PopupOptions.parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data("Usage: permission-popup [--host codex|claude|dsh] [--self-test]\n".utf8))
            Darwin.exit(1)
        }
        if options.selfTest {
            Darwin.exit(SelfTest.run() ? 0 : 1)
        }

        let host = options.host
        guard PopupSettings.isEnabled else { return }
        let input: Data
        if host == .dsh {
            // Bound DSH input before allocation; the existing Codex read path
            // stays untouched for strict compatibility.
            do {
                var data = Data()
                while data.count <= maximumInputBytes {
                    let count = min(64 * 1024, maximumInputBytes + 1 - data.count)
                    guard let chunk = try FileHandle.standardInput.read(upToCount: count),
                          !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                input = data
            } catch {
                DSHFailure.emit("DSH human authorization input could not be read; denied before Auto review.")
                return
            }
        } else {
            input = FileHandle.standardInput.readDataToEndOfFile()
        }
        guard let request = try? HookRequest.parse(input, host: host) else {
            if host == .dsh {
                DSHFailure.emit("Invalid DSH human authorization request; denied before Auto review.")
                return
            }
            debugLog("Input was not valid for \(host.displayName); returning no decision")
            return
        }

        guard host.shouldShow(request) else {
            if host == .dsh {
                DSHFailure.emit("DSH human authorization unavailable; denied before Auto review.")
                return
            }
            debugLog("Request is not eligible for \(host.displayName); returning no decision")
            return
        }

        // Resolve before queueing/activation; never steal focus to an unrelated
        // app that happens to be foreground when the user denies the request.
        let raiseHost: () -> Void
        switch host {
        case .codex:
            raiseHost = MainCodexApplication.raiseWindow
        case .claude, .dsh:
            let application = ClaudeHostApplication.capture()
            raiseHost = application.raiseWindow
        }
        let lifetime = configuredLifetime()
        let deadline = Date().addingTimeInterval(lifetime)
        guard let queueLock = RequestQueueLock() else {
            if host == .dsh {
                DSHFailure.emit("DSH human authorization queue unavailable; denied before Auto review.")
                return
            }
            debugLog("Could not create the popup queue lock; returning no decision")
            return
        }
        guard queueLock.acquire(until: deadline) else {
            guard PopupSettings.isEnabled else { return }
            if Date() >= deadline {
                debugLog("Popup queue deadline expired; denying the request")
                if let response = popupTimeoutDecision.responseData(for: host) {
                    FileHandle.standardOutput.write(response)
                    FileHandle.standardOutput.write(Data([0x0A]))
                } else if host == .dsh {
                    DSHFailure.emit("DSH human authorization timed out; denied before Auto review.")
                }
                raiseHost()
            } else {
                if host == .dsh {
                    DSHFailure.emit("DSH human authorization queue failed; denied before Auto review.")
                } else {
                    debugLog("Could not acquire the popup queue lock; returning no decision")
                }
            }
            return
        }

        withExtendedLifetime(queueLock) {
            guard PopupSettings.isEnabled else { return }
            let threadTitle: String?
            switch host {
            case .codex:
                threadTitle = ThreadTitleLookup.title(
                    for: request.sessionID, transcriptPath: request.transcriptPath)
            case .claude:
                threadTitle = ClaudeThreadTitleLookup.title(
                    for: request.sessionID, transcriptPath: request.transcriptPath)
            case .dsh:
                // DSH does not supply a Codex/Claude transcript. Never consult
                // either host's database or infer a title from conversation text.
                threadTitle = nil
            }
            if threadTitle == nil {
                debugLog("Thread title unavailable; continuing without it")
            }
            let controller = PermissionWindowController(
                request: request,
                threadTitle: threadTitle,
                hotKey: .fromEnvironment(),
                deadline: deadline,
                host: host,
                raiseHost: raiseHost
            )
            let decision = controller.run()
            if let response = decision.responseData(for: host) {
                FileHandle.standardOutput.write(response)
                FileHandle.standardOutput.write(Data([0x0A]))
            } else if host == .dsh {
                DSHFailure.emit("DSH human authorization produced no decision; denied before Auto review.")
            }
        }
    }

    private static func configuredLifetime() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        guard
            let raw = environment["PERMISSION_POPUP_TIMEOUT"]
                ?? environment["CODEX_PERMISSION_POPUP_TIMEOUT"],
            let value = TimeInterval(raw), value.isFinite
        else {
            return defaultLifetime
        }
        return min(max(value, 10), 590)
    }
}
