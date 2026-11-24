import AppKit

/// Every failure a user can run into has a stable code, so it can be looked up
/// on the error list (ERRORS.md) or pasted into an LLM. Add new codes here and
/// to ERRORS.md together. Codes are never reused or renumbered.
enum ErrorCode: String, CaseIterable {
    // 1xx — updates (reserved for the in-app updater)
    // 2xx — talking to AbleSet
    case socketFailed = "MAB-201"
    case portInUse = "MAB-202"
    case ableSetSilent = "MAB-203"
    case badHost = "MAB-204"
    // 3xx — talking to the MC4 PRO
    case midiFailed = "MAB-301"
    case pedalNotFound = "MAB-302"
    case sendFailed = "MAB-303"
    case pedalSilent = "MAB-304"
    case pedalRejected = "MAB-305"
    // 6xx — install.sh
    // 9xx — anything else
    case unexpected = "MAB-999"

    var summary: String {
        switch self {
        case .socketFailed: return "Couldn't open a network socket to talk to AbleSet."
        case .portInUse: return "MorningstarAblesetBridge's OSC listening port is already used by another app."
        case .ableSetSilent: return "AbleSet isn't answering over OSC."
        case .badHost: return "The AbleSet host address isn't a valid IP address."
        case .midiFailed: return "Couldn't start CoreMIDI."
        case .pedalNotFound: return "The MC4 PRO isn't connected to this Mac over MIDI."
        case .sendFailed: return "Sending a message to the MC4 PRO failed."
        case .pedalSilent: return "The MC4 PRO isn't answering MorningstarAblesetBridge's questions."
        case .pedalRejected: return "The MC4 PRO rejected a message from MorningstarAblesetBridge."
        case .unexpected: return "Something unexpected went wrong."
        }
    }

    var hint: String {
        switch self {
        case .socketFailed: return "Quit and reopen MorningstarAblesetBridge. If it keeps happening, restart the Mac."
        case .portInUse: return "Quit any other copy of MorningstarAblesetBridge (Ableton Live itself uses 39061), or pick another listening port: defaults write com.jonpike.morningstarablesetbridge listenPort -int 39162, then reopen MorningstarAblesetBridge."
        case .ableSetSilent: return "Open AbleSet and make sure it's running on this Mac (OSC port 39051). MorningstarAblesetBridge keeps retrying every few seconds."
        case .badHost: return "Reset it: defaults delete com.jonpike.morningstarablesetbridge ableSetHost, then reopen MorningstarAblesetBridge."
        case .midiFailed: return "Quit and reopen MorningstarAblesetBridge. If it keeps happening, restart the Mac."
        case .pedalNotFound: return "Connect the MC4 over Bluetooth (Audio MIDI Setup → MIDI Studio → Bluetooth) or USB. Bluetooth only reaches one host, so disconnect it from the iPad first."
        case .sendFailed, .pedalSilent: return "Reconnect the MC4 (Bluetooth or USB) and choose “Resend Everything to Pedal”. If it keeps happening, power-cycle the pedal."
        case .pedalRejected: return "Note the details (Copy Error Details) — the pedal's firmware may expect a different message layout."
        case .unexpected: return "Quit and reopen MorningstarAblesetBridge. If it keeps happening, copy the details and ask for help."
        }
    }
}

struct AppError: Error {
    let code: ErrorCode
    let details: String
    init(_ code: ErrorCode, _ details: String = "") { self.code = code; self.details = details }
}

enum ErrorReporter {
    static let listPage = "https://github.com/jonpikereally/MorningstarAblesetBridge/blob/main/ERRORS.md"
    static let listRaw = "https://raw.githubusercontent.com/jonpikereally/MorningstarAblesetBridge/main/ERRORS.md"
    static var hover: String { "Look this error code up on the MorningstarAblesetBridge error list: \(listPage)" }

    static func log(_ e: AppError) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let url = dir.appendingPathComponent("MorningstarAblesetBridge.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(e.code.rawValue) \(e.code.summary) \(e.details)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func details(_ e: AppError) -> String {
        """
        MorningstarAblesetBridge error \(e.code.rawValue): \(e.code.summary)
        Details: \(e.details.isEmpty ? "(none)" : e.details)
        What to try: \(e.code.hint)
        MorningstarAblesetBridge \(AppVersion.version) (built \(AppVersion.built)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Error list: \(listPage)
        Plain-text list for AI assistants: \(listRaw)
        """
    }

    static func show(_ e: AppError) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = e.code.summary
        alert.informativeText = "\(e.details.isEmpty ? "" : e.details + "\n\n")\(e.code.hint)\n\nError code: \(e.code.rawValue)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Error Details")
        alert.addButton(withTitle: "Open Error List")
        alert.layout()
        addTooltips(alert.window.contentView)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details(e), forType: .string)
        case .alertThirdButtonReturn:
            if let url = URL(string: listPage) { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    private static func addTooltips(_ view: NSView?) {
        guard let view else { return }
        if view is NSTextField { view.toolTip = hover }
        view.subviews.forEach(addTooltips)
    }
}
