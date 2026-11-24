import AppKit

/// Every failure a user can run into has a stable code, so it can be looked up
/// on the error list (ERRORS.md) or pasted into an LLM. Add new codes here and
/// to ERRORS.md together. Codes are never reused or renumbered.
enum ErrorCode: String, CaseIterable {
    // 1xx — updates
    case noUpdateSource = "MAB-101"
    case badUpdateSource = "MAB-102"
    case updateSourceUnreachable = "MAB-103"
    case updateServerError = "MAB-104"
    case updateInfoMalformed = "MAB-105"
    case updateDownloadFailed = "MAB-106"
    case updateUnpackFailed = "MAB-107"
    case updateMissingApp = "MAB-108"
    case updateWrongApp = "MAB-109"
    case updateDamagedApp = "MAB-110"
    case updateInstallerFailed = "MAB-111"
    case updateSwapFailed = "MAB-112"
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
        case .noUpdateSource: return "No update source is set."
        case .badUpdateSource: return "The update source isn't a web link or a file path."
        case .updateSourceUnreachable: return "Couldn't reach the update source."
        case .updateServerError: return "The update server returned an error."
        case .updateInfoMalformed: return "The update information is damaged or in the wrong format."
        case .updateDownloadFailed: return "Couldn't download the update."
        case .updateUnpackFailed: return "Couldn't unpack the downloaded update."
        case .updateMissingApp: return "The downloaded update doesn't contain MorningstarAblesetBridge."
        case .updateWrongApp: return "The downloaded update is a different app."
        case .updateDamagedApp: return "The downloaded update is damaged."
        case .updateInstallerFailed: return "Couldn't start installing the update."
        case .updateSwapFailed: return "Installing the update failed, so the previous version was kept."
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
        case .noUpdateSource, .badUpdateSource: return "Set one with “Update Source…” in the menu, or leave it empty to use the built-in source."
        case .updateSourceUnreachable: return "Check your internet connection and try again."
        case .updateServerError, .updateDownloadFailed: return "Try again in a few minutes. If it keeps happening, download the latest version from GitHub."
        case .updateInfoMalformed, .updateUnpackFailed, .updateMissingApp, .updateWrongApp, .updateDamagedApp: return "The published update is broken. Download the latest version from GitHub instead."
        case .updateInstallerFailed, .updateSwapFailed: return "Make sure MorningstarAblesetBridge is in ~/Applications and that the folder isn't locked, then try again."
        case .socketFailed: return "Quit and reopen MorningstarAblesetBridge. If it keeps happening, restart the Mac."
        case .portInUse: return "Quit any other copy of MorningstarAblesetBridge (Ableton Live itself uses 39061), or pick another listening port: defaults write com.jonpike.morningstarablesetbridge listenPort -int 39162, then reopen MorningstarAblesetBridge."
        case .ableSetSilent: return "Open AbleSet and make sure it's running on this Mac (OSC port 39051). MorningstarAblesetBridge keeps retrying every few seconds."
        case .badHost: return "Reset it: defaults delete com.jonpike.morningstarablesetbridge ableSetHost, then reopen MorningstarAblesetBridge."
        case .midiFailed: return "Quit and reopen MorningstarAblesetBridge. If it keeps happening, restart the Mac."
        case .pedalNotFound: return "Connect the MC4 over Bluetooth (Audio MIDI Setup → MIDI Studio → Bluetooth) or USB. Bluetooth only reaches one host, so disconnect it from the iPad first."
        case .sendFailed: return "Reconnect the MC4 (Bluetooth or USB) and choose “Resend Everything to Pedal”. If it keeps happening, power-cycle the pedal."
        case .pedalSilent: return "Song names keep updating anyway; only noticing bank changes needs the pedal's answers. Check Pedal MIDI Port → Find Pedal Automatically. If it keeps happening, send the log (menu → Show Log) to whoever helps you — it records what the pedal sent when its answers stopped."
        case .pedalRejected: return "Note the details (Copy Error Details) — the pedal's firmware may expect a different message layout."
        case .unexpected: return "Quit and reopen MorningstarAblesetBridge. If it keeps happening, copy the details and ask for help."
        }
    }
}

struct AppError: LocalizedError {
    let code: ErrorCode
    let details: String
    init(_ code: ErrorCode, _ details: String = "") { self.code = code; self.details = details }
    init(wrapping error: Error, as code: ErrorCode = .unexpected) {
        if let e = error as? AppError { self = e } else { self.init(code, error.localizedDescription) }
    }
    var errorDescription: String? { "\(code.summary) (\(code.rawValue))" }
}

enum ErrorReporter {
    static let listPage = "https://github.com/jonpikereally/MorningstarAblesetBridge/blob/main/ERRORS.md"
    static let listRaw = "https://raw.githubusercontent.com/jonpikereally/MorningstarAblesetBridge/main/ERRORS.md"
    static var hover: String { "Look this error code up on the MorningstarAblesetBridge error list: \(listPage)" }

    /// A plain diagnostic note in the same log (no user content).
    static func note(_ text: String) {
        append("\(ISO8601DateFormatter().string(from: Date())) NOTE \(text)\n")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MorningstarAblesetBridge.log")
    }

    private static func append(_ line: String) {
        let url = logURL
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func log(_ e: AppError) {
        append("\(ISO8601DateFormatter().string(from: Date())) \(e.code.rawValue) \(e.code.summary) \(e.details)\n")
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

    static func show(_ e: AppError) { present(e, title: e.code.summary) }

    /// Shows the error with its code. `actions` become extra buttons; returns
    /// the index of the action picked, or nil.
    @discardableResult
    static func present(_ e: AppError, title: String, actions: [String] = []) -> Int? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let lead = title == e.code.summary ? "" : e.code.summary + "\n\n"
        alert.informativeText = "\(lead)\(e.details.isEmpty ? "" : e.details + "\n\n")\(e.code.hint)\n\nError code: \(e.code.rawValue)"
        alert.addButton(withTitle: "OK")
        for a in actions { alert.addButton(withTitle: a) }
        alert.addButton(withTitle: "Copy Error Details")
        alert.addButton(withTitle: "Open Error List")
        alert.layout()
        alert.window.contentView?.toolTip = hover
        addTooltips(alert.window.contentView)
        let r = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if r == actions.count + 1 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details(e), forType: .string)
        } else if r == actions.count + 2 {
            if let url = URL(string: listPage) { NSWorkspace.shared.open(url) }
        } else if r >= 1 && r <= actions.count {
            return r - 1
        }
        return nil
    }

    private static func addTooltips(_ view: NSView?) {
        guard let view else { return }
        if view is NSTextField { view.toolTip = hover }
        view.subviews.forEach(addTooltips)
    }
}
