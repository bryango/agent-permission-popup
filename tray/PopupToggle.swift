import AppKit

private final class PopupToggleDelegate: NSObject, NSApplicationDelegate {
    private let settings = PopupToggleSettings()
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func refresh() {
        let enabled = settings.enabled
        let label = enabled ? "Ask — popup enabled" : "Auto — continue without popup"
        let symbol = enabled ? "hand.raised" : "bolt"
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        if !enabled, let source = image {
            let colored = NSImage(size: source.size)
            colored.lockFocus()
            source.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor(srgbRed: 1, green: 98.0 / 255, blue: 87.0 / 255, alpha: 1).setFill()
            NSRect(origin: .zero, size: source.size).fill(using: .sourceAtop)
            colored.unlockFocus()
            image = colored
        }
        image?.isTemplate = enabled
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = label + " — click to toggle; right-click to quit"
        statusItem?.button?.setAccessibilityLabel(label)
    }

    @objc private func clicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit AgentControl", action: #selector(quit(_:)), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 5), in: button)
            return
        }
        do {
            try settings.save(enabled: !settings.enabled)
            refresh()
        } catch {
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not change the popup setting"
            alert.informativeText = "The setting was not changed.\n\(settings.url.path)\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

@main
private struct PopupToggleMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = PopupToggleDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
