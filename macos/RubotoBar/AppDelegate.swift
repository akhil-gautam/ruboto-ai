import Cocoa
import Carbon

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var inputPanel: NSPanel?
    var inputField: NSTextField?
    var resultView: NSTextView?
    var isWorking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "R"
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        }

        // Menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Quick Input...", action: #selector(showQuickInput), keyEquivalent: "r")
        menu.addItem(withTitle: "Morning Briefing", action: #selector(runMorningBriefing), keyEquivalent: "")
        menu.addItem(withTitle: "Open Terminal", action: #selector(openTerminal), keyEquivalent: "t")

        let recentItem = NSMenuItem(title: "Recent Tasks", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit RubotoBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu

        // Register global hotkey: Cmd+Shift+R
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 {
                DispatchQueue.main.async {
                    self?.showQuickInput()
                }
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 {
                DispatchQueue.main.async {
                    self?.showQuickInput()
                }
                return nil
            }
            return event
        }

        refreshRecentTasks()
    }

    @objc func showQuickInput() {
        if let panel = inputPanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            inputField?.selectText(nil)
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = "Ruboto Quick Input"
        panel.isFloatingPanel = true
        panel.center()

        if let screen = NSScreen.main {
            let x = (screen.frame.width - 500) / 2
            let y = screen.frame.height - 300
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))

        let field = NSTextField(frame: NSRect(x: 20, y: 160, width: 460, height: 24))
        field.placeholderString = "Ask Ruboto anything..."
        field.target = self
        field.action = #selector(submitQuickInput(_:))
        contentView.addSubview(field)
        self.inputField = field

        if !frontApp.isEmpty {
            let label = NSTextField(labelWithString: "Context: \(frontApp)")
            label.frame = NSRect(x: 20, y: 135, width: 460, height: 18)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            contentView.addSubview(label)
        }

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 460, height: 108))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = ""
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        contentView.addSubview(scrollView)
        self.resultView = textView

        panel.contentView = contentView
        self.inputPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        field.becomeFirstResponder()
    }

    @objc func submitQuickInput(_ sender: NSTextField) {
        let request = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        resultView?.string = "Working..."
        statusItem.button?.title = "R\u{00B7}"
        isWorking = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runRuboto(request: request, context: frontApp.isEmpty ? nil : "app:\(frontApp)")
            DispatchQueue.main.async {
                self?.resultView?.string = result ?? "No response"
                self?.statusItem.button?.title = "R"
                self?.isWorking = false
            }
        }
    }

    @objc func runMorningBriefing() {
        statusItem.button?.title = "R\u{00B7}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runRuboto(args: ["--briefing", "morning"])
            DispatchQueue.main.async {
                self?.statusItem.button?.title = "R"
                if let result = result, !result.isEmpty {
                    self?.showNotification(title: "Morning Briefing", body: String(result.prefix(200)))
                }
            }
        }
    }

    @objc func openTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "ruboto-ai"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func refreshRecentTasks() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let result = self?.runRuboto(args: ["--tasks", "5"])
            DispatchQueue.main.async {
                guard let self = self, let result = result else { return }
                let recentItem = self.statusItem.menu?.item(withTitle: "Recent Tasks")
                let submenu = recentItem?.submenu ?? NSMenu()
                submenu.removeAllItems()
                let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
                if lines.isEmpty {
                    submenu.addItem(withTitle: "No recent tasks", action: nil, keyEquivalent: "")
                } else {
                    for line in lines.prefix(10) {
                        submenu.addItem(withTitle: String(line.prefix(60)), action: nil, keyEquivalent: "")
                    }
                }
                recentItem?.submenu = submenu
            }
        }
    }

    func runRuboto(request: String? = nil, context: String? = nil, args: [String]? = nil) -> String? {
        let rubotoPath = findRubotoPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = ["ruby", rubotoPath]
        if let args = args {
            arguments.append(contentsOf: args)
        } else if let request = request {
            arguments.append("--quick")
            arguments.append(request)
            if let context = context {
                arguments.append("--context")
                arguments.append(context)
            }
        }
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func findRubotoPath() -> String {
        let bundlePath = Bundle.main.bundlePath
        let projectDir = URL(fileURLWithPath: bundlePath)
            .deletingLastPathComponent() // build/
            .deletingLastPathComponent() // RubotoBar/
            .deletingLastPathComponent() // macos/
        let binPath = projectDir.appendingPathComponent("bin/ruboto-ai").path
        if FileManager.default.fileExists(atPath: binPath) {
            return binPath
        }
        return "ruboto-ai"
    }

    func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }
}
