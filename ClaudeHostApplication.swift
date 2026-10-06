import AppKit
import Darwin
import Foundation

// Capture the owner before our popup changes focus. Never use the current
// frontmost app: the user may be working in an unrelated application.
struct ClaudeHostApplication {
    private let application: NSRunningApplication?

    static func capture() -> ClaudeHostApplication {
        let environment = ProcessInfo.processInfo.environment
        if let bundleID = environment["PERMISSION_POPUP_HOST_BUNDLE_ID"], !bundleID.isEmpty {
            return ClaudeHostApplication(application:
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first(where: { $0.activationPolicy == .regular && !$0.isTerminated }))
        }

        let owner = ownerPID(startingAt: getppid(), parentOf: parentPID) { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.activationPolicy == .regular && !app.isTerminated
        }
        return ClaudeHostApplication(application: owner.flatMap {
            NSRunningApplication(processIdentifier: $0)
        })
    }

    func raiseWindow() {
        guard let application, !application.isTerminated else { return }
        application.unhide()
        application.activate(options: [.activateAllWindows])
        // Reopen the captured, still-running app to restore a closed/minimized
        // main window. This is app-level activation, not terminal-tab selection.
        if let url = application.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    static func ownerPID(
        startingAt start: pid_t,
        parentOf: (pid_t) -> pid_t?,
        isApplication: (pid_t) -> Bool
    ) -> pid_t? {
        var pid = start
        var visited = Set<pid_t>()
        for _ in 0..<64 {
            guard pid > 1, visited.insert(pid).inserted else { return nil }
            if isApplication(pid) { return pid }
            guard let parent = parentOf(pid) else { return nil }
            pid = parent
        }
        return nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}

enum ClaudeHostApplicationTests {
    static func failures() -> [String] {
        var failures: [String] = []
        let parents: [pid_t: pid_t] = [12: 11, 11: 10, 10: 1]
        if ClaudeHostApplication.ownerPID(startingAt: 12, parentOf: { parents[$0] },
                                          isApplication: { $0 == 10 }) != 10 {
            failures.append("Claude finds owning app through shell ancestors")
        }
        if ClaudeHostApplication.ownerPID(startingAt: 12, parentOf: { parents[$0] },
                                          isApplication: { _ in false }) != nil {
            failures.append("Claude unknown owner does not guess frontmost app")
        }
        if ClaudeHostApplication.ownerPID(startingAt: 12, parentOf: { _ in 12 },
                                          isApplication: { _ in false }) != nil {
            failures.append("Claude owner lookup terminates on cycle")
        }
        return failures
    }
}
