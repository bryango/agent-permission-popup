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
    FileHandle.standardError.write(Data("[agent-permission-popup] \(message)\n".utf8))
}

private enum PopupHost: String {
    case codex
    case claude
    case dsh

    // Embedded provider marks from OpenCodex's bundled provider-icons assets.
    // Keep the helper self-contained; no app install or network is needed.
    var headingIcon: NSImage? {
        let svg: String
        switch self {
        case .codex:
            svg = ##"<svg fill="#10A37F" fill-rule="evenodd" style="flex:none;line-height:1" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>OpenAI</title><path d="M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z"></path></svg>"##
        case .claude:
            svg = ##"<svg style="flex:none;line-height:1" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>Claude</title><path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z" fill="#D97757" fill-rule="nonzero"></path></svg>"##
        case .dsh:
            svg = ##"<svg role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><title>DeepSeek</title><path fill="#4D6BFE" d="M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.828-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.003-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.231 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3.101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113.074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.25 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-.156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45"/></svg>"##
        }
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = self == .codex
        return image
    }


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
            .appendingPathComponent("agent-permission-popup.lock")
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
        let headingFont = NSFont.systemFont(ofSize: 26, weight: .semibold)
        title.font = headingFont
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 3
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.cell?.usesSingleLineMode = false
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = displayThreadTitle?.value

        let iconSize = headingFont.pointSize
        let icon = NSImageView()
        icon.image = host.headingIcon
        if host == .codex {
            icon.contentTintColor = .labelColor
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityLabel(host.displayName)
        let heading = NSView()
        heading.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        heading.addSubview(icon)
        heading.addSubview(title)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            // Align with the first line, including when the title wraps.
            icon.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor,
                constant: -headingFont.capHeight / 2),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            title.topAnchor.constraint(equalTo: heading.topAnchor),
            title.bottomAnchor.constraint(equalTo: heading.bottomAnchor),
        ])

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

        root.addArrangedSubview(heading)
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
            heading.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
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
            .appendingPathComponent("agent-permission-popup-\(UUID().uuidString).jsonl")
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
            .appendingPathComponent("agent-permission-popup-\(UUID().uuidString)")
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
        for host in [PopupHost.codex, .claude, .dsh] {
            let icon = host.headingIcon
            expect(icon?.size == NSSize(width: 24, height: 24),
                   "\(host.displayName) heading icon size", into: &failures)
            expect(icon?.tiffRepresentation != nil,
                   "\(host.displayName) heading icon renders", into: &failures)
        }
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
