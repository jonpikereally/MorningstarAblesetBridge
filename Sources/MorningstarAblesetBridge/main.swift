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
        refreshTitle()
    }

    func refreshTitle() {
        let s = bridge.state
        let mark = !bridge.problems.isEmpty ? "⚠︎" : !s.playing ? "■" : s.loop ? "↻" : "▶"
        item.button?.title = "MC4 \(mark)"
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
        info("MorningstarAblesetBridge \(AppVersion.version) (built \(AppVersion.built))")
        menu.addItem(NSMenuItem(title: "Quit MorningstarAblesetBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func showProblem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let code = ErrorCode(rawValue: raw),
              let e = bridge.problems[code] else { return }
        ErrorReporter.show(e)
    }

    @objc func resend() { bridge.resendAll() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
