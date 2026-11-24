import AppKit

// MorningstarAblesetBridge: shows AbleSet's song, tempo and play/loop state on a Morningstar
// MC4 PRO, and turns its switch A into Play (stopped) / Loop toggle (playing).
//
//   MorningstarAblesetBridge --selftest        offline checks of the message encoding
//   MorningstarAblesetBridge --probe [--write] talk to the pedal from Terminal and print replies

let arguments = CommandLine.arguments
if arguments.contains("--selftest") { exit(SelfTest.run()) }
if arguments.contains("--probe") { Probe.run(write: arguments.contains("--write")) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let bridge = Bridge()
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        bridge.onChange = { [weak self] in self?.refreshTitle() }
        bridge.start()
        Updater.shared.onChange = { [weak self] in self?.refreshTitle() }
        Updater.shared.startAutomaticChecks()
        reportFailedUpdateIfAny()
        refreshTitle()
    }

    func refreshTitle() {
        let s = bridge.state
        let mark = !bridge.problems.isEmpty ? "⚠︎" : !s.playing ? "■" : s.loop ? "↻" : "▶"
        item.button?.title = "MC4 \(mark)" + (Updater.shared.available != nil ? " ⬆︎" : "")
        item.button?.toolTip = bridge.problems.isEmpty ? "MorningstarAblesetBridge" : ErrorReporter.hover
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = bridge.state
        func info(_ text: String) { let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }

        if bridge.ableSetAlive {
            info("AbleSet: connected")
            let position = s.songIndex.map { " (\($0 + 1)/\(s.songs.count))" } ?? ""
            info("    \(s.songName.isEmpty ? "No song" : s.songName)\(position)\(s.tempo.map { String(format: " · %.0f BPM", $0) } ?? "")")
            info("    \(s.playing ? "Playing" : "Stopped") · loop \(s.loop ? "on" : "off")")
            if !s.nextName.isEmpty { info("    Next: \(s.nextName)") }
        } else {
            info("AbleSet: not answering on port \(bridge.ableSetPort)")
        }
        menu.addItem(.separator())
        if let name = bridge.midi.destinationName {
            info("Pedal: \(name)")
            switch bridge.inBank {
            case true?: info("    AbleSet Bridge bank is showing")
            case false?: info("    Another bank is showing (the bridge waits)")
            case nil: info("    Asking the pedal which bank is showing…")
            }
        } else {
            info("Pedal: no MIDI device named “\(bridge.midi.match)”")
        }

        if !bridge.problems.isEmpty {
            menu.addItem(.separator())
            for e in bridge.problems.values.sorted(by: { $0.code.rawValue < $1.code.rawValue }) {
                let i = NSMenuItem(title: "⚠️ Problem \(e.code.rawValue) — click for details", action: #selector(showProblem(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = e.code.rawValue
                i.toolTip = "\(e.code.summary)\n\(ErrorReporter.hover)"
                menu.addItem(i)
            }
        }

        menu.addItem(.separator())
        let resend = NSMenuItem(title: "Resend Everything to Pedal", action: #selector(resend), keyEquivalent: "r")
        resend.target = self
        menu.addItem(resend)
        menu.addItem(.separator())
        let update = NSMenuItem(title: checking ? "Checking for Updates…"
                                    : Updater.shared.available.map { "⬆︎ Install Update to v\($0.version)…" } ?? "Check for Updates…",
                                action: checking ? nil : #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let source = NSMenuItem(title: "Update Source…", action: #selector(editUpdateSource), keyEquivalent: "")
        source.target = self
        menu.addItem(source)
        let github = NSMenuItem(title: "MorningstarAblesetBridge on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)
        info("MorningstarAblesetBridge \(AppVersion.version) (built \(AppVersion.built))")
        menu.addItem(NSMenuItem(title: "Quit MorningstarAblesetBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func showProblem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let code = ErrorCode(rawValue: raw),
              let e = bridge.problems[code] else { return }
        ErrorReporter.show(e)
    }

    @objc func resend() { bridge.resendAll() }

    // MARK: Updates (same behaviour as Jon's other apps)

    private var checking = false

    @objc private func checkForUpdates() {
        if let m = Updater.shared.available { offerInstall(m); return }
        checking = true
        Updater.shared.check { [weak self] result in
            guard let self else { return }
            self.checking = false
            self.refreshTitle()
            switch result {
            case .success(let m?):
                self.offerInstall(m)
            case .success(nil):
                let alert = NSAlert()
                alert.messageText = "MorningstarAblesetBridge is up to date"
                alert.informativeText = "You're running v\(AppVersion.version), the newest version available."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failure(let error):
                self.showUpdateError(error)
            }
        }
    }

    private func offerInstall(_ m: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Update to MorningstarAblesetBridge v\(m.version)?"
        var text = "You have v\(AppVersion.version)."
        if let notes = m.notes, !notes.isEmpty { text += "\n\nWhat's new:\n\(notes)" }
        text += "\n\nMorningstarAblesetBridge will quit, update itself and reopen. Your settings are kept, "
            + "and there are no permissions to grant again."
        alert.informativeText = text
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        checking = true
        Updater.shared.install(m) { [weak self] error in
            self?.checking = false
            self?.showUpdateError(error)
        }
    }

    private func showUpdateError(_ error: Error) {
        let e = AppError(wrapping: error)
        ErrorReporter.log(e)
        let sourceProblem = e.code == .noUpdateSource || e.code == .badUpdateSource
        let picked = ErrorReporter.present(e, title: "Couldn't update MorningstarAblesetBridge",
                                           actions: sourceProblem ? ["Set Update Source…"] : [])
        if picked == 0 { editUpdateSource() }
    }

    /// The swap script leaves a coded marker when installing an update fails
    /// and it has put the previous version back.
    private func reportFailedUpdateIfAny() {
        let marker = Updater.swapFailureMarker
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: marker)
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        let code = parts.first.flatMap { ErrorCode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .updateSwapFailed
        let e = AppError(code, parts.count > 1 ? parts[1] : "")
        ErrorReporter.log(e)
        DispatchQueue.main.async { ErrorReporter.present(e, title: "Couldn't install the update") }
    }

    @objc private func editUpdateSource() {
        let alert = NSAlert()
        alert.messageText = "Update Source"
        alert.informativeText = "Where MorningstarAblesetBridge looks for new versions: a web link or a file path to a latest.json feed. "
            + "Leave it empty to use the built-in source"
            + (AppVersion.updateFeed.isEmpty ? " (none in this build)." : ":\n\(AppVersion.updateFeed)")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "updateFeed") ?? ""
        field.placeholderString = AppVersion.updateFeed.isEmpty ? "https://…/latest.json" : AppVersion.updateFeed
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && Updater.url(from: value) == nil {
            showUpdateError(AppError(.badUpdateSource, value))
            return
        }
        Updater.shared.feed = value
        Updater.shared.check { _ in }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/jonpikereally/MorningstarAblesetBridge") { NSWorkspace.shared.open(url) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
