import AppKit
import CoreMIDI

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
        if midi.exactName == nil, midi.matchingPortNames().count > 1 {
            var done = false
            midi.search { hits in
                midi.autoPick = hits.first { midi.matchingPortNames().contains($0) }
                midi.rescan(); done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        guard midi.isConnected else { print("!! MAB-302: no pedal port matching “\(midi.match)”"); exit(2) }
        print("Pedal: \(midi.destinationName!)")
        let p = 4
        if let i = CommandLine.arguments.firstIndex(of: "--show") {
            // --show "LABEL:bg:text:led,LABEL:bg:text:led,…" each for --seconds (default 8), twice.
            let args = CommandLine.arguments
            let each = args.firstIndex(of: "--seconds").flatMap { j in j + 1 < args.count ? Double(args[j + 1]) : nil } ?? 8
            let items = (i + 1 < args.count ? args[i + 1] : "").split(separator: ",").map { $0.split(separator: ":").map(String.init) }
            for _ in 0..<2 {
                for it in items where it.count == 4 {
                    guard let bg = UInt8(it[1]), let tx = UInt8(it[2]), let led = UInt8(it[3]) else { continue }
                    print("\(it[0])  background \(bg), text \(tx), light \(led)")
                    midi.send(Morningstar.setName(.short, preset: p, it[0]))
                    midi.send(Morningstar.setName(.toggle, preset: p, it[0]))
                    midi.send(Morningstar.colours(preset: p, led: led, ledToggle: led, text: tx, background: bg))
                    RunLoop.main.run(until: Date().addingTimeInterval(each))
                }
            }
            print("\nDone. Change bank and come back to restore LOOP.")
            exit(0)
        }
        if CommandLine.arguments.contains("--sweep") {
            // Every solid colour number on LOOP's background (text and light the
            // same number), with the number as LOOP's name, 3 s each.
            let args = CommandLine.arguments
            let from = args.firstIndex(of: "--from").flatMap { i in i + 1 < args.count ? UInt8(args[i + 1]) : nil } ?? 0
            let values: [UInt8] = (Array(0...14) + Array(29...63)).filter { $0 >= from }
            let each = args.firstIndex(of: "--seconds").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil } ?? 3
            for v in values {
                print("BG \(v)  (\(Int(each)) s)")
                midi.send(Morningstar.setName(.short, preset: p, "BG \(v)"))
                midi.send(Morningstar.setName(.toggle, preset: p, "BG \(v)"))
                midi.send(Morningstar.colours(preset: p, led: v, ledToggle: v, text: v == 0 ? 7 : 0, background: v))
                RunLoop.main.run(until: Date().addingTimeInterval(each))
            }
            print("\nDone. Change bank and come back to restore LOOP.")
            exit(0)
        }
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
        var last = SetState()
        last.apply(OSCMessage(address: "/setlist/songs", args: [.string("One"), .string("Two")]))
        last.apply(OSCMessage(address: "/setlist/activeSongIndex", args: [.float(1)]))
        last.apply(OSCMessage(address: "/setlist/nextSongName", args: [.string("One")]))
        check(PedalView.nextLabel(last) == "-", "last song in the setlist: no next song, whatever AbleSet's nextSongName says")
        last.apply(OSCMessage(address: "/setlist/activeSongIndex", args: [.float(0)]))
        check(PedalView.nextLabel(last, bpm: false, key: false) == "Two", "next song comes from the setlist order")
        var k = SetState()
        k.apply(OSCMessage(address: "/setlist/activeSongName", args: [.string("Red")]))
        k.apply(OSCMessage(address: "/setlist/activeSongDescription", args: [.string("Key: Am")]))
        check(k.key == "Am", "key from the active song's description")
        k.apply(OSCMessage(address: "/setlist/activeSongName", args: [.string("Blue")]))
        check(k.key == nil, "a song without a key shows none (the last song's description doesn't carry over)")
        check(SetState.key(description: "", tags: ["#e"], name: "Intro (a)") == nil, "lowercase letters aren't keys")
        check(SetState.key(description: "", tags: ["#F#m"], name: "x") == "F#m", "a capital key tag still works")
        var sec = SetState()
        sec.apply(OSCMessage(address: "/setlist/activeSongName", args: [.string("Red")]))
        check(PedalView.previousSectionLabel(sec) == "PREV SECTION" && PedalView.nextSectionLabel(sec) == "NEXT SECTION", "no sections known: section switches keep the bank's names")
        sec.apply(OSCMessage(address: "/setlist/sections", args: [.string("Intro"), .string("Verse"), .string("Chorus")]))
        sec.apply(OSCMessage(address: "/setlist/activeSectionIndex", args: [.float(1)]))
        sec.apply(OSCMessage(address: "/setlist/activeSectionName", args: [.string("Verse")]))
        check(PedalView.previousSectionLabel(sec) == "Intro" && PedalView.nextSectionLabel(sec) == "Chorus", "previous / next section from the song's section list")
        check(PedalView.bankTitle(sec, bpm: false, key: false, section: true) == "Red", "song mode: no section on the screen")
        sec.sectionMode = true
        check(PedalView.bankTitle(sec, bpm: false, key: false, section: true, songTitle: true) == "Red - Verse", "section mode: current section after the song on the screen")
        check(PedalView.bankTitle(sec, bpm: false, key: false, section: true, songTitle: false) == "Verse", "section mode with the song title hidden: section alone")
        check(Bridge.isOurTitle("Verse 120", sent: [], current: "", songs: ["Red", "Intro", "Verse"]), "a section-only title is still recognised after a restart")
        check(PedalView.bankTitle(sec, bpm: false, key: false, section: false) == "Red", "section on the screen can be switched off")
        sec.apply(OSCMessage(address: "/setlist/activeSectionIndex", args: [.float(2)]))
        check(PedalView.nextSectionLabel(sec) == "-", "last section: no next section")
        check(Bridge.isOurTitle("Red 125 (Am) - Chorus", sent: [], current: "", songs: ["Red"]), "a title with a section is still recognised")
        check(PedalView.split("Getaway Car 86 (C)", head: "Getaway Car") == "Getaway Car\\n86 (C)", "long title: song on line 1, BPM and key on line 2")
        check(PedalView.split("Somebody That I Used To Know", head: "Somebody That I Used To Know") == "Somebody That\\nI Used To Know", "long name alone: split at the middle space")
        var short = SetState(); short.apply(OSCMessage(address: "/setlist/activeSongName", args: [.string("Red")]))
        check(!PedalView.screenTitle(short, twoLines: true).contains("\\n"), "short titles stay on one line")
        check(Bridge.isOurTitle("Getaway Car\\n86 (C)", sent: [], current: "", songs: ["Getaway Car"]), "a two-line title is still recognised")
        let sentT: Set<String> = ["Red 125 (Am)"]
        check(Bridge.isOurTitle("Red 125 (Am)", sent: sentT, current: "", songs: []), "bank title we wrote is ours")
        check(Bridge.isOurTitle("Red 125 (A", sent: sentT, current: "", songs: []), "a title the pedal cut short is still ours")
        check(Bridge.isOurTitle("Red  125  (Am) ", sent: sentT, current: "", songs: []), "extra spaces don't matter")
        check(Bridge.isOurTitle("Blue Moon 98", sent: [], current: "", songs: ["Blue Moon"]), "another Mac's title for a setlist song is ours")
        check(!Bridge.isOurTitle("Arrow Keys", sent: sentT, current: "", songs: ["Red", "Blue Moon"]), "another bank isn't ours")
        check(!Bridge.isOurTitle("Re", sent: sentT, current: "", songs: []), "a tiny fragment isn't enough")
        let echo = Morningstar.controllerInfo()
        var reply = echo; reply[5] = 0x01; reply[reply.count - 2] = Morningstar.checksum(reply.dropLast(2))
        check(!PedalMIDI.containsMorningstarReply(echo) && PedalMIDI.containsMorningstarReply(reply),
              "port search ignores our own question echoing back (IAC) but accepts a pedal reply")
        let msgs = PedalView.messages(s)
        check(msgs.count == 1 + 2 * 3 + 2 * 2 + 2 * 2, "bank name + LOOP names/colour on pages 2 and 4 + C/D song names on pages 1/2 + section names on 3/4")
        check(!msgs.contains { $0.bytes[7] == 0x03 }, "no long names are ever written")
        let colourOps = msgs.filter { $0.bytes[7] == 0x05 }
        check(Set(colourOps.map { $0.bytes[8] }) == [4, 12], "only LOOP (pages 2/4) is ever recoloured")
        check(PedalView.loopColour(s) == 14, "LOOP ON is 14 (yellow on Jon's pedal)")
        var off = s; off.loop = false
        check(PedalView.loopColour(off) == 13, "LOOP OFF is 13 (a slightly different yellow on Jon's pedal)")
        let touched = Set(msgs.dropFirst().map { $0.bytes[8] })
        check(touched == [4, 12, 2, 6, 3, 7, 10, 14, 11, 15], "only LOOP (pages 2/4) and C/D are relabelled; PLAY and STOP never")
        check(!touched.contains(0) && !touched.contains(8) && !touched.contains(1), "PLAY and STOP are left as the bank has them")

        let sub = OSCMessage(address: "/subscribe", args: [.string("127.0.0.1"), .int(39161), .string("MorningstarAblesetBridge")])
        let back = OSCMessage.decode(sub.encoded())
        check(back.first?.address == "/subscribe" && back.first?.args == sub.args, "OSC /subscribe round-trips")

        // v2.7 stability fixes. Each of these crashed, froze or misbehaved before.
        check(OSCMessage.decode(Data([0x2F, 0x61, 0, 0, 0x2C, 0x73, 0])).isEmpty, "a cut-off OSC packet is skipped, not a crash")
        func bundle(_ inner: Data) -> Data {
            var b = Data("#bundle".utf8) + Data(repeating: 0, count: 9)      // "#bundle\0" + 8-byte time tag
            var n = UInt32(inner.count).bigEndian
            b.append(Data(bytes: &n, count: 4)); b.append(inner)
            return b
        }
        var nest = OSCMessage(address: "/x", args: []).encoded()
        check(OSCMessage.decode(bundle(nest)).count == 1, "a bundle (as AbleSet sends them) still decodes")
        for _ in 0..<3000 { nest = bundle(nest) }
        check(OSCMessage.decode(nest).isEmpty, "bundles nested thousands deep are skipped, not a stack overflow")

        var junk = SetState(); junk.songs = ["A", "B", "C"]; junk.songName = "A"
        junk.apply(OSCMessage(address: "/setlist/activeSongIndex", args: [.float(.nan)]))
        check(junk.songIndex == nil, "a NaN song index is ignored, not a crash")
        junk.apply(OSCMessage(address: "/setlist/activeSongIndex", args: [.string("inf")]))
        check(junk.songIndex == nil, "an infinite song index is ignored")
        junk.apply(OSCMessage(address: "/setlist/activeSongIndex", args: [.int(-3)]))
        check(junk.nextSong == nil && PedalView.messages(junk).count == 15, "a song index below -1 shows no next song, not a crash")
        junk.apply(OSCMessage(address: "/global/tempo", args: [.float(1e30)]))
        check(PedalView.bankTitle(junk, bpm: true, key: false) == "A", "an impossible tempo isn't shown")
        check(PedalView.bpmText(1e30).hasPrefix("1"), "a huge number in bpmText doesn't crash")
        check(Bridge.port(70_000, or: 39161) == 39161 && Bridge.port(-5, or: 39161) == 39161
              && Bridge.port(0, or: 39161) == 39161 && Bridge.port(39162, or: 39161) == 39162,
              "an impossible port number in the settings falls back to the default")

        let pm = PedalMIDI()
        var heard: [String] = []
        pm.onControlChange = { _, n, v in heard.append("CC\(n)=\(v)") }
        pm.onSysex = { _ in heard.append("SysEx") }
        pm.receive([0xF0, 0x00, 0x21, 0x24, 0x09, 0x01, 0x70, 0x30])         // a reply whose F7 never came
        pm.receive([0xB0, 0x6F, 0x00])                                       // then the bank's CC 111 = 0
        check(heard == ["CC111=0"] && pm.cutOffSysex == 1, "a CC after an unfinished SysEx is still heard")
        pm.receive([0xF0, 0x00, 0xF8, 0x21, 0xF7])
        check(heard.last == "SysEx", "real-time bytes inside a SysEx are skipped and the SysEx still arrives")

        var box: [PedalMIDI.Queued] = []
        for item: PedalMIDI.Queued in [("bank", [1]), ("C0", [2]), (nil, [3]), ("bank", [4]), (nil, [5])] { PedalMIDI.enqueue(&box, item) }
        check(box.map { $0.bytes } == [[4], [2], [3], [5]], "a newer message for the same switch replaces the waiting one")

        var recent = RecentTitles(limit: 3)
        for t in ["a", "b", "c", "b", "d"] { recent.insert(t) }
        check(recent.all == ["b", "c", "d"], "only the newest bank titles are remembered")

        let page = Int(getpagesize())
        if let base = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), base != MAP_FAILED {
            mprotect(base + page, page, PROT_NONE)
            let p = base + page - 20                  // a 2-word packet ending right where memory stops
            p.storeBytes(of: UInt64(0), as: UInt64.self)
            p.storeBytes(of: UInt32(2), toByteOffset: 8, as: UInt32.self)
            p.storeBytes(of: UInt32(0x3006_0021), toByteOffset: 12, as: UInt32.self)   // SysEx7, complete, 6 bytes
            p.storeBytes(of: UInt32(0x2409_0170), toByteOffset: 16, as: UInt32.self)
            let got = PedalMIDI.bytes(fromUMP: UnsafePointer<MIDIEventPacket>(OpaquePointer(p)))
            check(got == [0xF0, 0x00, 0x21, 0x24, 0x09, 0x01, 0x70, 0xF7], "MIDI packets are read only as far as their own words")
            munmap(base, page * 2)
        }

        let osc = OSCTransport()
        var reopened = false
        if (try? osc.open(host: "127.0.0.1", sendPort: 39_878, listenPort: 39_877)) != nil {
            osc.close()
            reopened = (try? osc.open(host: "127.0.0.1", sendPort: 39_879, listenPort: 39_877)) != nil
            osc.close()
        }
        check(reopened, "the listening port can be reopened straight away (AbleSet Ports… → Save)")

        // The freeze: timers and main-queue work must keep going while the menu is
        // open (event tracking) or an alert is showing (modal panel).
        let app = NSApplication.shared                 // makes those run-loop modes "common"
        app.setActivationPolicy(.prohibited)
        func spin(_ mode: RunLoop.Mode, _ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { _ = RunLoop.current.run(mode: mode, before: end) }
        }
        var ticks = 0
        let timer = Timer.common(0.02) { ticks += 1 }
        spin(.eventTracking, 0.25)
        let menuTicks = ticks
        spin(.modalPanel, 0.25)
        timer.invalidate()
        check(menuTicks > 3 && ticks > menuTicks + 3, "timers keep running while the menu or an alert is open")
        var duringAlert = -1
        DispatchQueue.main.async {                     // like an update-check or Find Pedal completion
            outsideMainQueue {
                var drained = 0
                for _ in 0..<5 { DispatchQueue.main.async { drained += 1 } }
                spin(.modalPanel, 0.25)                // the alert it shows
                duringAlert = drained
            }
        }
        while duringAlert < 0 { spin(.default, 0.05) }
        check(duringAlert == 5, "AbleSet and pedal messages keep flowing while an alert from a completion is open")

        // v2.8: reconnecting over Bluetooth, driven by a pretend radio.
        let mc4 = RadioDevice(id: UUID(), name: "MC4 PRO")
        let widi = RadioDevice(id: UUID(), name: "WIDI Master")
        var clock = Date()
        var problemsNow: [String] = []
        var online = false
        func reconnector(_ radio: FakeRadio) -> BluetoothReconnect {
            let b = BluetoothReconnect(makeRadio: { radio })
            b.usesTimer = false
            b.now = { clock }
            b.log = { _ in }
            b.isPedal = { Bridge.isPedalName($0.name, match: "MC4", exactName: nil) }
            b.isOnline = { _ in online }
            b.raise = { e in if !problemsNow.contains(e.code.rawValue) { problemsNow.append(e.code.rawValue) } }
            b.clear = { c in problemsNow.removeAll { $0 == c.rawValue } }
            return b
        }
        func later(_ seconds: TimeInterval, _ b: BluetoothReconnect) { clock += seconds; b.tick() }
        func toHandOver(_ r: FakeRadio, _ b: BluetoothReconnect) {
            b.look(for: 600, asked: false); r.onEvent(.state(.on)); r.onEvent(.found(mc4)); r.onEvent(.connected(mc4.id))
        }

        let r1 = FakeRadio(), b1 = reconnector(r1)
        b1.look(for: 600, asked: false)
        r1.onEvent(.state(.on)); r1.onEvent(.found(widi)); r1.onEvent(.found(mc4)); r1.onEvent(.connected(mc4.id))
        check(r1.calls == ["start", "scan", "stop scan", "connect", "activate"] && b1.phase == .handingOver(mc4),
              "Bluetooth: finds the pedal by name, connects, and hands it to CoreMIDI")
        b1.pedalArrived()
        check(r1.calls.last == "disconnect" && b1.phase == .idle && b1.seen == ["WIDI Master"],
              "Bluetooth: once CoreMIDI has the pedal, the app lets go of its own link")
        r1.onEvent(.state(.off))
        check(problemsNow.isEmpty, "Bluetooth switched off while nothing is being looked for isn't a problem")

        let r2 = FakeRadio(), b2 = reconnector(r2)
        r2.alreadyConnected = [widi, mc4]
        b2.look(for: 600, asked: false); r2.onEvent(.state(.on))
        check(r2.calls == ["start", "connect"], "Bluetooth: a pedal already linked to the Mac is connected without a scan")
        b2.stop("test")

        let r3 = FakeRadio(), b3 = reconnector(r3)
        b3.look(for: Bridge.askedLookSeconds, asked: true); r3.onEvent(.state(.on))
        later(60, b3)
        let stillLooking = b3.phase == .looking && problemsNow.isEmpty
        later(61, b3)
        check(stillLooking && b3.phase == .idle && problemsNow == ["MAB-308"] && r3.calls.last == "stop scan",
              "Bluetooth: Reconnect looks for 2 minutes, then says the pedal didn't turn up (MAB-308)")
        problemsNow = []

        let r4 = FakeRadio(), b4 = reconnector(r4)
        b4.look(for: Bridge.autoLookSeconds, asked: false); r4.onEvent(.state(.on))
        later(601, b4)
        let endedAt = b4.gaveUpAt
        b4.look(for: 600, asked: false)
        check(b4.phase == .starting && problemsNow.isEmpty && endedAt != nil && b4.gaveUpAt == nil,
              "Bluetooth: an automatic look ends quietly after 10 minutes (the menu says when)")
        b4.stop("test")

        let r5 = FakeRadio(), b5 = reconnector(r5)
        b5.look(for: 600, asked: false); r5.onEvent(.state(.off))
        check(b5.phase == .starting && problemsNow == ["MAB-306"], "Bluetooth off: says so (MAB-306) and waits for it")
        r5.onEvent(.state(.on))
        check(b5.phase == .looking && problemsNow.isEmpty, "Bluetooth switched on: the problem clears and the look starts")
        b5.stop("test")

        let r6 = FakeRadio(), b6 = reconnector(r6)
        b6.look(for: 120, asked: true); r6.onEvent(.state(.notAllowed))
        check(problemsNow == ["MAB-307"] && b6.phase == .starting, "Bluetooth not allowed: says so (MAB-307)")
        b6.stop("test"); problemsNow = []

        let r7 = FakeRadio(), b7 = reconnector(r7)
        r7.activateStatus = -50
        toHandOver(r7, b7)
        check(b7.phase == .idle && problemsNow == ["MAB-309"] && r7.calls.last == "disconnect",
              "Bluetooth: CoreMIDI refusing the pedal is reported (MAB-309) and the link let go")
        problemsNow = []

        let r8 = FakeRadio(), b8 = reconnector(r8)
        toHandOver(r8, b8)
        later(11, b8)
        check(b8.phase == .idle && problemsNow == ["MAB-309"] && r8.calls.last == "disconnect",
              "Bluetooth: CoreMIDI not listing the pedal within 10 s is reported (MAB-309)")
        problemsNow = []
        let r8b = FakeRadio(), b8b = reconnector(r8b)
        toHandOver(r8b, b8b)
        online = true; later(1, b8b); online = false
        check(b8b.phase == .idle && problemsNow.isEmpty && r8b.calls.last == "disconnect",
              "Bluetooth: the pedal turning up in CoreMIDI completes the hand-over")

        let r9 = FakeRadio(), b9 = reconnector(r9)
        b9.look(for: 600, asked: false); r9.onEvent(.state(.on)); r9.onEvent(.found(mc4))
        later(16, b9)
        check(b9.phase == .looking && Array(r9.calls.suffix(2)) == ["disconnect", "scan"],
              "Bluetooth: a connection that hangs is cancelled and the look goes on")
        r9.onEvent(.connected(widi.id))
        check(b9.phase == .looking && r9.calls.last == "disconnect", "Bluetooth: a late connection nobody waits for is let go")
        b9.pedalArrived()
        check(b9.phase == .idle && r9.calls.last == "stop scan", "Bluetooth: the pedal coming back another way (USB, macOS's window) ends the look")

        let r10 = FakeRadio(), b10 = reconnector(r10)
        b10.look(for: 600, asked: false); r10.onEvent(.state(.on)); r10.onEvent(.found(mc4)); r10.onEvent(.disconnected(mc4.id))
        check(b10.phase == .looking, "Bluetooth: losing the pedal mid-connection goes back to looking")
        b10.stop("test")

        let r11 = FakeRadio(), b11 = reconnector(r11)
        for _ in 0..<3 { toHandOver(r11, b11); b11.pedalArrived(); clock += 60 }
        let refused = !b11.look(for: 600, asked: false)
        let allowedByHand = b11.look(for: 120, asked: true)
        b11.stop("test")
        clock += 600
        check(refused && allowedByHand && b11.look(for: 600, asked: false),
              "Bluetooth: after 3 reconnects in 10 minutes only Reconnect looks, until 10 minutes have passed")
        b11.stop("test")

        check(Bridge.isPedalName("MC4 PRO", match: "MC4", exactName: nil) && !Bridge.isPedalName("WIDI Master", match: "MC4", exactName: nil),
              "Bluetooth: the pedal is told apart from other Bluetooth MIDI devices by name")
        check(Bridge.isPedalName("Morningstar 12", match: "MC4", exactName: "Morningstar 12 Bluetooth")
              && !Bridge.isPedalName("", match: "MC4", exactName: "MC4 PRO Bluetooth") && !Bridge.isPedalName("MC4 PRO", match: "", exactName: nil),
              "Bluetooth: a picked port's name also identifies the pedal; empty names match nothing")
        check(Bridge.bluetoothHoldOff(asked: true, exactName: "Morningstar MC4 Pro Port 4", automatic: true, manager: nil) != nil
              && Bridge.bluetoothHoldOff(asked: true, exactName: nil, automatic: false, manager: "Audio MIDI Setup") == nil
              && Bridge.bluetoothHoldOff(asked: false, exactName: "MC4 PRO 12 Bluetooth", automatic: true, manager: nil) == nil,
              "Bluetooth: Reconnect always looks, unless a USB port was picked by hand")
        check(Bridge.bluetoothHoldOff(asked: false, exactName: nil, automatic: false, manager: nil) != nil
              && Bridge.bluetoothHoldOff(asked: false, exactName: nil, automatic: true, manager: "Audio MIDI Setup") != nil,
              "Bluetooth: automatic looks follow the menu switch and wait while a Bluetooth MIDI window is open")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}

/// A pretend Bluetooth radio for --selftest: records what the reconnect logic asks of it.
final class FakeRadio: BluetoothRadio {
    var onEvent: (RadioEvent) -> Void = { _ in }
    var calls: [String] = []
    var alreadyConnected: [RadioDevice] = []
    var activateStatus: OSStatus = noErr
    func start() { calls.append("start") }
    func connectedMIDIDevices() -> [RadioDevice] { alreadyConnected }
    func scan(_ on: Bool) { calls.append(on ? "scan" : "stop scan") }
    func connect(_ id: UUID) { calls.append("connect") }
    func disconnect(_ id: UUID) { calls.append("disconnect") }
    func activateMIDI() -> OSStatus { calls.append("activate"); return activateStatus }
}
