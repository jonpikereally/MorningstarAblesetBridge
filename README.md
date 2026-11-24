# MorningstarAblesetBridge

A macOS menu bar app that puts [AbleSet](https://ableset.com) on a Morningstar **MC4 PRO** footswitch:

```
Page 1 (stopped)                       Page 2 (playing)
C  <previous song>  D  <next song>     C  <previous song>  D  <next song>
A  PLAY             B  STOP            A  LOOP ON / OFF    B  STOP
          screen: "<current song> <BPM>"
```

**The pedal controls AbleSet by itself. The app only changes what you see.** Every switch sends its own MIDI note straight to AbleSet and turns pages by itself, so the pedal works exactly the same whether the app is running or not. The app never sends AbleSet a play, stop or loop command.

- **A** on page 1 is **PLAY**: it plays, then the pedal flips to page 2, where **A** is **LOOP** (loop on/off). **B** (STOP) stops and flips to the other page.
- The bank name on the pedal's screen shows the current song and tempo, and a new song's name flashes on screen when the song changes.
- **C** and **D** are renamed to the previous and next song names.
- **LOOP** shows AbleSet's real loop state: **LOOP ON** (yellow) or **LOOP OFF** (gold, a slightly deeper yellow). Without the app it shows the pedal's own guess.
- The app never changes PLAY's or STOP's colour or text. They always look exactly as the bank sets them.
- The pedal only knows its own presses. If AbleSet stops by itself (end of song, or stopped from the computer), the pedal stays on page 2 until you press STOP, with or without the app.

It reads AbleSet's state over OSC and drives the pedal with Morningstar's [SysEx API for external applications](https://help.morningstar.io/en/article/sysex-documentation-for-external-applications-1n7gb7c/). It works over whatever MIDI link the Mac has to the pedal; Bluetooth has been tested, USB should work the same way. Every change is **temporary**: nothing is saved on the pedal, and its own names come back when you change banks. The bridge only writes while the **AbleSet Bridge** bank is showing.

## Install

1. Download **[MorningstarAblesetBridge.zip](https://github.com/jonpikereally/MorningstarAblesetBridge/raw/main/updates/MorningstarAblesetBridge.zip)** and unzip it.
2. Double-click **Install MorningstarAblesetBridge.command**. If macOS blocks it, right-click it, choose **Open**, then **Open** again.
3. Look for **MC4** in the menu bar. The app checks this repo for updates on its own (menu → Check for Updates…).

## Pedal side

Load [`bank/AbleSet Bridge.json`](bank/) into a bank slot with the Morningstar editor (Restore / Load from File). It is made by `python3 tools/make_bank.py`, and its switches are the same as the **AbleSet Play-Loop** bank's. In that bank:

| Switch | Sends (ch 1) | Then |
|---|---|---|
| A, page 1 | Note 12: PLAY | goes to page 2 |
| A, page 2 | Note 14: LOOP on/off | stays on page 2 |
| B | Note 13: STOP (held: note 19) | goes to the other page |
| C | Note 15: previous song | |
| D | Note 16: next song | |
| entering / leaving the bank | CC 111 = 127 / 0 | only tells the app the bank is showing |

Notes go out as Note On on press and Note Off on release, and the page change happens on release. Pages 3 and 4 repeat 1 and 2, so the A+B / C+D page combos never land on a blank page.

Map notes 12, 13, 14, 15 and 16 (and 19 if you like) in AbleSet's MIDI mapping. They are the same notes as the MC6 Playback Ableset and AbleSet Play-Loop banks, so an existing mapping already covers them. **Don't map CC 111.**

## Ableton Live side

In Live → Settings → Link, Tempo & MIDI, turn on **Remote** for the pedal's **input** port (MC4 PRO … Bluetooth, or the USB port). On one Mac the bridge received nothing from the pedal until this was on, even though Live doesn't need to map anything. Leave **Sync** off for the pedal's output.

## AbleSet side

AbleSet's OSC server must be reachable on UDP 39051, which is the default. The bridge subscribes with `/subscribe 127.0.0.1 39161 MorningstarAblesetBridge`. It listens on 39161 because Ableton Live itself uses 39061. If AbleSet restarts, the bridge re-subscribes within a few seconds.

## Build, test, install

Command Line Tools are enough; Xcode isn't needed.

```
./build.sh
./MorningstarAblesetBridge.app/Contents/MacOS/MorningstarAblesetBridge --selftest          # offline checks
./MorningstarAblesetBridge.app/Contents/MacOS/MorningstarAblesetBridge --probe             # ask the pedal its names
./MorningstarAblesetBridge.app/Contents/MacOS/MorningstarAblesetBridge --probe --write     # + temporary rename / LCD test
./MorningstarAblesetBridge.app/Contents/MacOS/MorningstarAblesetBridge --probe --raw       # + print every incoming MIDI packet
./MorningstarAblesetBridge.app/Contents/MacOS/MorningstarAblesetBridge --find              # which MIDI port answers as the pedal
python3 tools/ableset_osc_probe.py                                                         # dump AbleSet's OSC values
./install.sh                                                                               # to ~/Applications, then open it
```

To ship an update: bump `VERSION`, write `RELEASE_NOTES.txt`, run `./release.sh`, then commit and push `updates/`. Every installed copy offers it within six hours.

**Show on Pedal** (menu) switches the BPM and key on or off (shown like `Red 125 (Am)`), separately for the current song (on the screen) and for the previous and next songs (C and D). AbleSet has no key field, so the key comes from, in order: `Key: Am` in the song's description (locator text like `Red {Key: Am}`), a description that's only the key (`Red {Am}`), a tag that looks like a key (`#Am`, `#F#`), or a key in brackets at the end of the name (`Red (Am)`). When none is found, the menu shows what AbleSet sent for the song.

In the menu, **Pedal MIDI Port** picks the pedal's port: **Find Pedal Automatically** asks every MIDI port a Morningstar question and uses the one that answers. You can also pick a port from the list or type its name. **AbleSet Ports…** sets the OSC ports.

Settings (`defaults write com.jonpike.morningstarablesetbridge <key> <value>`):

| Key | Default | Meaning |
|---|---|---|
| `pedalPort` | (none) | Exact MIDI port name; set by the Pedal MIDI Port menu |
| `pedalName` | `MC4` | Text matched inside the pedal's MIDI port name when `pedalPort` isn't set |
| `listenPort` | 39161 | UDP port for AbleSet's updates |
| `ableSetPort` | 39051 | AbleSet's OSC port |
| `ableSetHost` | 127.0.0.1 | AbleSet's computer |

## Things learned the hard way

- On one playback Mac the bridge heard nothing from the pedal over Bluetooth until Live's **Remote** was switched on for the pedal's input, while sending to the pedal worked the whole time. The bridge's log line "received 0 chunks" is the sign of this.
- The pedal's SysEx replies only arrive through CoreMIDI's MIDI 1.0 *protocol* input API (`MIDIInputPortCreateWithProtocol`, SysEx as UMP type 3). The older packet-list API received nothing from the MC4 over Bluetooth.
- The MC4 replies to "get current bank name" (0x30) with op2 `30`, not `21` as the docs say. Byte 5 of every reply is `01`.
- Preset numbers in the SysEx API count across pages: page 2's A is preset 4. PRO-series names are 32 characters.

## Errors

Every problem shows an error code (`MAB-xxx`) in the menu, with a **Copy Error Details** button. See [ERRORS.md](ERRORS.md).
