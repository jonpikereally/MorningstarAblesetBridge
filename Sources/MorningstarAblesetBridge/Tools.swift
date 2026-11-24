import Foundation

/// `--probe`: lists MIDI endpoints, asks the pedal who it is and what its
/// switches are called, and prints every reply. Read-only unless `--write`,
/// which renames preset A temporarily and flashes the LCD (both revert when
/// the pedal changes bank). Must run outside Claude's sandbox (it hides MIDI).
enum Probe {
    static func run(write: Bool) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("MIDI destinations:")
        PedalMIDI.endpoints(sources: false).forEach { print("  ", PedalMIDI.name($0)) }
        print("MIDI sources:")
        PedalMIDI.endpoints(sources: true).forEach { print("  ", PedalMIDI.name($0)) }

        let midi = PedalMIDI()
        midi.match = UserDefaults.standard.string(forKey: "pedalName") ?? "MC4"
        midi.onSysex = { b in
            guard let r = Morningstar.parse(b) else { print("<- (not a Morningstar reply) \(Morningstar.hex(b))"); return }
            let printable = r.payload.allSatisfy { (32..<127).contains($0) }
            print(String(format: "<- op2 %02X op3 %02X op4 %02X txn %02X  ", r.op2, r.op3, r.op4, r.txn)
                  + (printable ? "“\(r.text)”" : Morningstar.hex(r.payload)))
        }
        midi.onControlChange = { ch, n, v in print("<- CC \(n) = \(v) on ch \(ch)") }
        midi.onSendError = { print("!! \($0.code.rawValue) \($0.details)") }
        if CommandLine.arguments.contains("--raw") { PedalMIDI.debug = true; midi.onRaw = { print("<< raw", Morningstar.hex($0)) } }
        do { try midi.start() } catch { print("!! \(error)"); exit(1) }
        guard midi.isConnected else { print("!! MAB-302: no destination containing “\(midi.match)”"); exit(2) }
        print("Pedal: \(midi.destinationName!)\n")

        func ask(_ label: String, _ bytes: [UInt8]) {
            midi.send(bytes)
            print("-> \(label)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        }
        ask("controller info", Morningstar.controllerInfo())
        ask("current bank name", Morningstar.currentBankName())
        for p in 0..<16 { ask("short name preset \(p)", Morningstar.getName(.short, preset: p, txn: UInt8(p))) }
        ask("toggle name preset 15 (MorningstarAblesetBridge marker)", Morningstar.getName(.toggle, preset: 15, txn: 0x11))
        if write {
            ask("TEMP rename preset 0 → “PROBE OK”", Morningstar.setName(.short, preset: 0, "PROBE OK"))
            ask("TEMP rename preset 4 → “PAGE2 OK”", Morningstar.setName(.short, preset: 4, "PAGE2 OK"))
            ask("TEMP bank name → “MorningstarAblesetBridge probe”", Morningstar.setBankName("MorningstarAblesetBridge probe"))
            ask("TEMP LED preset 0 → orange", Morningstar.colours(preset: 0, led: PedalView.orange))
            ask("LCD message 3 s", Morningstar.lcd("MorningstarAblesetBridge probe", tenths: 30))
            ask("read back short name preset 0", Morningstar.getName(.short, preset: 0, txn: 0x20))
        }
        let wait = CommandLine.arguments.contains("--raw") ? 25.0 : 4.0
        print("\nListening \(Int(wait)) s more (press a switch to see what it sends)…")
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        exit(0)
    }
}

extension Probe {
    /// `--colourtest`: sends LOOP (page 2 A, preset 4) a few known colour sets,
    /// 12 s each, with the test number on the LCD, so Jon can say what each
    /// looked like. Temporary: changing bank restores the bank's colours.
    static func colourTest() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let midi = PedalMIDI()
        midi.match = UserDefaults.standard.string(forKey: "pedalName") ?? "MC4"
        midi.exactName = UserDefaults.standard.string(forKey: "pedalPort")
        do { try midi.start() } catch { print("!! \(error)"); exit(1) }
        guard midi.isConnected else { print("!! MAB-302: no pedal port matching “\(midi.match)”"); exit(2) }
        print("Pedal: \(midi.destinationName!)")
        let p = 4
        let tests: [(String, [UInt8])] = [
            ("TEST 1: LED red, white text, blue background",
             Morningstar.message(0x05, op3: UInt8(p), payload: [0x7E, 0x7E, 0x7E, 0x7E, 9, 9, 9, 7, 7, 7, 2, 2, 2])),
            ("TEST 2: exactly what MAB sends for LOOP ON (yellow, black text)",
             Morningstar.colours(preset: p, led: 4, ledToggle: 4, text: 0, background: 4)),
            ("TEST 3: same as 2 but 7F in the first four bytes",
             Morningstar.message(0x05, op3: UInt8(p), payload: [0x7F, 0x7F, 0x7F, 0x7F, 4, 4, 4, 0, 0, 0, 4, 4, 4])),
            ("TEST 4: only 9 colour bytes, no toggle/blink/scroll/group",
             Morningstar.message(0x05, op3: UInt8(p), payload: [4, 4, 4, 0, 0, 0, 4, 4, 4])),
        ]
        for (i, t) in tests.enumerated() {
            print("\n\(t.0)\n   bytes: \(Morningstar.hex(t.1))")
            midi.send(Morningstar.lcd("COLOUR TEST \(i + 1)", tenths: 30))
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            midi.send(t.1)
            RunLoop.main.run(until: Date().addingTimeInterval(12))
        }
        print("\nDone. Change bank and come back to restore LOOP's own colours.")
        exit(0)
    }

    /// `--find`: the same search as the menu's "Find Pedal Automatically".
    static func find() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("MIDI ports:"); PedalMIDI.portNames().forEach { print("   ", $0) }
        let midi = PedalMIDI()
        midi.match = "\u{1}never"              // connect nothing normally; only the search listens
        do { try midi.start() } catch { print("!! \(error)"); exit(1) }
        print("\nAsking every port a Morningstar question…")
        midi.search { hits in
            print(hits.isEmpty ? "No port answered." : "Answered: " + hits.joined(separator: ", "))
            exit(hits.isEmpty ? 2 : 0)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(10))
        exit(3)
    }
}

/// `--selftest`: offline checks, runnable in the sandbox.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

        // The documented Bank Up example: F0 00 21 24 id 00 70 00 00 00 00 00 00 00 00 00 cs F7
        let bankUp = Morningstar.message(0x00)
        check(bankUp.count == 18 && bankUp.prefix(7) == [0xF0, 0x00, 0x21, 0x24, 0x09, 0x00, 0x70], "header layout + 18-byte length")
        let xor = bankUp.dropLast(2).reduce(UInt8(0), ^) & 0x7F
        check(bankUp[16] == xor, "checksum is XOR of every byte before it, & 0x7F (= \(String(format: "%02X", xor)))")
        check(Morningstar.parse(bankUp) != nil, "parser accepts its own messages")
        var bad = bankUp; bad[16] ^= 1
        check(Morningstar.parse(bad) == nil, "parser rejects a bad checksum")

        let name = Morningstar.setName(.short, preset: 6, "Café “Song”")
        check(name.count == 16 + 32 + 2, "names are padded to 32 bytes")
        check(name[7] == 0x01 && name[8] == 6 && name[9] == 0, "short name: op2 01, op3 preset, op4 00 (not saved)")
        check(String(decoding: name[16..<27], as: UTF8.self) == "Cafe \"Song\"", "accents and curly quotes become ASCII")
        check(name[16...].dropLast(2).allSatisfy { $0 < 0x80 }, "payload is 7-bit")
        check(Morningstar.setName(.long, preset: 0, "x")[7] == 0x03, "long name op2 03")
        check(Morningstar.getName(.toggle, preset: 15)[7] == 0x22, "get toggle name op2 22")
        let lcd = Morningstar.lcd(String(repeating: "x", count: 40), tenths: 25)
        check(lcd[7] == 0x11 && lcd[9] == 25 && lcd.count == 16 + 20 + 2, "LCD message: op2 11, duration in op4, max 20 chars")
        let col = Morningstar.colours(preset: 2, led: 8)
        check(col[7] == 0x05 && col[11] == 0 && col.count == 16 + 13 + 2, "colours: op2 05, save flag (op6) 00, 13-byte payload")

        var s = SetState()
        for m in [OSCMessage(address: "/setlist/songs", args: [.string("One"), .string("Two"), .string("Three")]),
                  OSCMessage(address: "/setlist/activeSongIndex", args: [.float(1)]),
                  OSCMessage(address: "/setlist/activeSongName", args: [.string("Two")]),
                  OSCMessage(address: "/setlist/nextSongName", args: [.string("Three")]),
                  OSCMessage(address: "/global/tempo", args: [.float(120)]),
                  OSCMessage(address: "/global/isPlaying", args: [.int(1)])] { s.apply(m) }
        check(s.previousName == "One" && PedalView.bankTitle(s, bpm: true, key: true) == "Two 120", "state → previous song + bank title")
        s.apply(OSCMessage(address: "/setlist/activeSongDescription", args: [.string("Capo 2, Key: F#m")]))
        check(s.key == "F#m" && PedalView.bankTitle(s, bpm: true, key: true) == "Two 120 (F#m)", "key from the description")
        check(PedalView.bankTitle(s, bpm: false, key: true) == "Two (F#m)" && PedalView.bankTitle(s, bpm: true, key: false) == "Two 120", "Show BPM / Show Key toggles")
        s.apply(OSCMessage(address: "/setlist/activeSongDescription", args: []))
        s.apply(OSCMessage(address: "/setlist/activeSongTags", args: [.string("#rock"), .string("#Bbm")]))
        check(s.key == "Bbm", "key from a tag")
        s.apply(OSCMessage(address: "/setlist/activeSongTags", args: []))
        check(SetState.key(description: "Am", tags: [], name: "x") == "Am", "description that is only a key")
        check(SetState.key(description: "", tags: [], name: "Red (F#m)") == "F#m", "key in brackets at the end of the name")
        check(SetState.key(description: "", tags: [], name: "Mine") == nil, "no key → nothing")
        s.apply(OSCMessage(address: "/setlist/songTempos", args: [.float(90), .float(120), .float(140.5)]))
        s.apply(OSCMessage(address: "/setlist/songDescriptions", args: [.string("Key: C"), .string(""), .string("{Key: Eb}")]))
        check(PedalView.previousLabel(s, bpm: true, key: true) == "One 90 (C)", "previous song with BPM and key")
        check(PedalView.nextLabel(s, bpm: true, key: true) == "Three 140.5 (Eb)", "next song with BPM and key")
        check(PedalView.nextLabel(s, bpm: false, key: false) == "Three", "previous/next toggles off → name only")
        check(PedalView.loopLabel(s) == "LOOP OFF", "LOOP switch says LOOP OFF")
        s.apply(OSCMessage(address: "/setlist/loopEnabled", args: [.bool(true)]))
        check(PedalView.loopLabel(s) == "LOOP ON", "LOOP switch says LOOP ON when loop is on")
        s.apply(OSCMessage(address: "/global/isPlaying", args: [.float(0)]))
        check(PedalView.loopLabel(s) == "LOOP ON", "LOOP switch keeps the loop state when stopped")
        let echo = Morningstar.controllerInfo()
        var reply = echo; reply[5] = 0x01; reply[reply.count - 2] = Morningstar.checksum(reply.dropLast(2))
        check(!PedalMIDI.containsMorningstarReply(echo) && PedalMIDI.containsMorningstarReply(reply),
              "port search ignores our own question echoing back (IAC) but accepts a pedal reply")
        let msgs = PedalView.messages(s)
        check(msgs.count == 1 + 2 * 3 + 4 * 4, "bank name + LOOP names/colour on pages 2 and 4 + C/D on every page")
        let colourOps = msgs.filter { $0.bytes[7] == 0x05 }
        check(Set(colourOps.map { $0.bytes[8] }) == [4, 12], "only LOOP (pages 2/4) is ever recoloured")
        check(PedalView.loopColour(s) == PedalView.yellow, "LOOP ON is yellow")
        var off = s; off.loop = false
        check(PedalView.loopColour(off) == PedalView.gold && PedalView.gold != PedalView.yellow, "LOOP OFF is a slightly different yellow (gold)")
        let touched = Set(msgs.dropFirst().map { $0.bytes[8] })
        check(touched == [4, 12, 2, 6, 10, 14, 3, 7, 11, 15], "only LOOP (pages 2/4), C and D are relabelled")
        check(!touched.contains(0) && !touched.contains(8) && !touched.contains(1), "PLAY and STOP are left as the bank has them")

        let sub = OSCMessage(address: "/subscribe", args: [.string("127.0.0.1"), .int(39161), .string("MorningstarAblesetBridge")])
        let back = OSCMessage.decode(sub.encoded())
        check(back.first?.address == "/subscribe" && back.first?.args == sub.args, "OSC /subscribe round-trips")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
