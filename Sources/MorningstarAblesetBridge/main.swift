import AppKit
import CoreAudioKit

// MorningstarAblesetBridge: shows AbleSet's song, tempo and play/loop state on a Morningstar
// MC4 PRO, and turns its switch A into Play (stopped) / Loop toggle (playing).
//
//   MorningstarAblesetBridge --selftest        offline checks of the message encoding
//   MorningstarAblesetBridge --probe [--write] talk to the pedal from Terminal and print replies
//   MorningstarAblesetBridge --find            list MIDI ports and which one answers as a Morningstar pedal

let arguments = CommandLine.arguments
if arguments.contains("--selftest") { exit(SelfTest.run()) }
if arguments.contains("--probe") { Probe.run(write: arguments.contains("--write")) }
if arguments.contains("--find") { Probe.find() }
if arguments.contains("--colourtest") { Probe.colourTest() }

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
            info("    \(s.playing ? "Playing" : "Stopped") · loop \(s.loop ? "on" : "off")\(s.key.map { " · key \($0)" } ?? "")")
            if let n = s.nextSong { info("    Next: \(n)") }
            if s.key == nil, !s.songName.isEmpty {
                // Shows what AbleSet sent, so a missing key can be traced.
                let d = s.songDescription.isEmpty ? "none" : "“\(s.songDescription.prefix(40))”"
                let t = s.songTags.isEmpty ? "none" : s.songTags.joined(separator: " ")
                info("    No key found · description \(d) · tags \(t)")
            }
        } else {
            info("AbleSet: not answering on port \(bridge.ableSetPort)")
        }
        menu.addItem(.separator())
        if let name = bridge.midi.destinationName {
            info("Pedal: \(name)")
            if let input = bridge.midi.sourceName, input != name { info("    Listening to: \(input)") }
            if bridge.midi.sourceName == nil { info("    No matching MIDI input — the pedal can't be heard") }
            switch bridge.inBank {
            case true?: info("    AbleSet Bridge bank is showing")
            case false?: info("    Another bank is showing (the bridge waits)")
            case nil: info("    Asking the pedal which bank is showing…")
            }
        } else if let exact = bridge.pedalPort {
            info("Pedal: MIDI port “\(exact)” isn't connected")
        } else {
            info("Pedal: no MIDI device named “\(bridge.midi.match)”")
        }
        menu.addItem(portMenu())
        let osc = NSMenuItem(title: "AbleSet Ports…", action: #selector(editAbleSetPorts), keyEquivalent: "")
        osc.target = self
        menu.addItem(osc)

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
        let show = NSMenuItem(title: "Show on Pedal", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        func toggle(_ title: String, _ on: Bool, _ tag: Int, _ tip: String? = nil) {
            let i = NSMenuItem(title: title, action: #selector(toggleShow(_:)), keyEquivalent: "")
            i.target = self; i.tag = tag; i.state = on ? .on : .off; i.toolTip = tip
            sub.addItem(i)
        }
        let keyTip = "Read from the song's AbleSet description (locator “Red {Key: Am}”), a key tag like #Am, or a key in brackets at the end of the name (“Red (Am)”)."
        func header(_ t: String) { let h = NSMenuItem(title: t, action: nil, keyEquivalent: ""); h.isEnabled = false; sub.addItem(h) }
        header("Current song (screen)")
        toggle("BPM", PedalView.showBPM, 1)
        toggle("Key", PedalView.showKey, 2, keyTip)
        sub.addItem(.separator())
        header("Previous / next songs (C and D)")
        toggle("BPM", PedalView.showNeighbourBPM, 3)
        toggle("Key", PedalView.showNeighbourKey, 4, keyTip)
        show.submenu = sub
        menu.addItem(show)
        let bt = NSMenuItem(title: "Connect Bluetooth MIDI Device…", action: #selector(connectBluetooth), keyEquivalent: "")
        bt.target = self
        bt.toolTip = "macOS's own Bluetooth MIDI window (the one in Audio MIDI Setup): click Connect next to the MC4 PRO"
        menu.addItem(bt)
        let reconnect = NSMenuItem(title: "Reconnect", action: #selector(reconnectPedal), keyEquivalent: "")
        reconnect.target = self
        reconnect.toolTip = "Reopen the pedal's MIDI connection and AbleSet's, then rewrite the pedal's names"
        menu.addItem(reconnect)
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
        let log = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
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
    @objc func reconnectPedal() { bridge.reconnect() }

    /// macOS's Bluetooth MIDI window, the same one Audio MIDI Setup opens from
    /// MIDI Studio → Bluetooth. Once the pedal connects, CoreMIDI announces the
    /// new device and the bridge picks it up by itself.
    private var bluetoothWindow: CABTLEMIDIWindowController?
    @objc func connectBluetooth() {
        if bluetoothWindow == nil { bluetoothWindow = CABTLEMIDIWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        bluetoothWindow?.showWindow(nil)
        bluetoothWindow?.window?.center()
        bluetoothWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleShow(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: PedalView.showBPM.toggle()
        case 2: PedalView.showKey.toggle()
        case 3: PedalView.showNeighbourBPM.toggle()
        default: PedalView.showNeighbourKey.toggle()
        }
        bridge.displaySettingsChanged()
    }

    // MARK: Ports

    private var finding = false

    private func portMenu() -> NSMenuItem {
        let top = NSMenuItem(title: "Pedal MIDI Port", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let find = NSMenuItem(title: finding ? "Searching…" : "Find Pedal Automatically",
                              action: finding ? nil : #selector(findPedal), keyEquivalent: "")
        find.target = self
        find.toolTip = "Asks every MIDI port a Morningstar question and uses the one that answers."
        sub.addItem(find)
        sub.addItem(.separator())
        let auto = NSMenuItem(title: "Automatic (first port named “\(bridge.midi.match)”)", action: #selector(pickPort(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = bridge.pedalPort == nil ? .on : .off
        sub.addItem(auto)
        var names = PedalMIDI.portNames()
        if let exact = bridge.pedalPort, !names.contains(exact) { names.append(exact) }
        for name in names {
            let i = NSMenuItem(title: name, action: #selector(pickPort(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            i.state = bridge.pedalPort == name ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let type = NSMenuItem(title: "Type a Port Name…", action: #selector(typePort), keyEquivalent: "")
        type.target = self
        sub.addItem(type)
        top.submenu = sub
        return top
    }

    @objc private func pickPort(_ sender: NSMenuItem) {
        bridge.usePedalPort(sender.representedObject as? String)
    }

    @objc private func findPedal() {
        finding = true
        bridge.findPedal { [weak self] hits in
            self?.finding = false
            let alert = NSAlert()
            if hits.isEmpty {
                alert.messageText = "No Morningstar pedal answered"
                alert.informativeText = "None of this Mac's MIDI ports replied. Check the MC4 is connected to this Mac "
                    + "(Bluetooth: menu → Connect Bluetooth MIDI Device…; Bluetooth reaches one computer at a time), then try again."
            } else {
                alert.messageText = "Using “\(self?.bridge.pedalPort ?? hits[0])”"
                alert.informativeText = hits.count > 1
                    ? "These ports answered: \(hits.joined(separator: ", ")). You can pick another one under Pedal MIDI Port."
                    : "That MIDI port answered as a Morningstar pedal."
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func typePort() {
        let alert = NSAlert()
        alert.messageText = "Pedal MIDI Port"
        alert.informativeText = "The exact name of the MIDI port the pedal uses, as Audio MIDI Setup shows it. Leave it empty for automatic."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = bridge.pedalPort ?? ""
        field.placeholderString = "MC4 PRO …"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use This Port")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bridge.usePedalPort(field.stringValue)
    }

    @objc private func editAbleSetPorts() {
        let alert = NSAlert()
        alert.messageText = "AbleSet Ports"
        alert.informativeText = "AbleSet listens for OSC on 39051 unless you changed it in AbleSet's settings. "
            + "The bridge listens for AbleSet's updates on its own port (39161); pick another if something else uses it. "
            + "Don't use 39061: Ableton Live uses that one."
        let ableSet = NSTextField(frame: NSRect(x: 0, y: 30, width: 120, height: 24))
        ableSet.stringValue = String(bridge.ableSetPort)
        ableSet.placeholderString = "39051"
        let listen = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        listen.stringValue = String(bridge.listenPort)
        listen.placeholderString = "39161"
        let l1 = NSTextField(labelWithString: "AbleSet's port"); l1.frame = NSRect(x: 130, y: 33, width: 200, height: 18)
        let l2 = NSTextField(labelWithString: "Bridge listens on"); l2.frame = NSRect(x: 130, y: 3, width: 200, height: 18)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 56))
        [ableSet, listen, l1, l2].forEach(box.addSubview)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = ableSet
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let a = UInt16(ableSet.stringValue.trimmingCharacters(in: .whitespaces)), a > 0,
              let l = UInt16(listen.stringValue.trimmingCharacters(in: .whitespaces)), l > 0, a != l else {
            NSSound.beep()
            return
        }
        bridge.useAbleSetPorts(listen: l, ableSet: a)
    }

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
            + "and the only permission it may ask for again is Bluetooth (used by Connect Bluetooth MIDI Device…)."
        if Bundle.main.bundleURL.path.contains("/AppTranslocation/") {
            text += "\n\nThis copy was opened straight from a download, so the update will be installed in "
                + "~/Applications. Delete the downloaded copy afterwards."
        }
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

    @objc private func showLog() {
        let url = ErrorReporter.logURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let alert = NSAlert()
            alert.messageText = "Nothing logged yet"
            alert.informativeText = "The log appears at ~/Library/Logs/MorningstarAblesetBridge.log after the first problem."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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
