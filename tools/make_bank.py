#!/usr/bin/env python3
"""Writes bank/AbleSet Bridge.json, the MC4 PRO bank for MorningstarAblesetBridge.

The pedal controls AbleSet on its own. MAB only changes what the pedal shows,
so every switch works the same with or without MAB running.

  Page 1 (stopped)                 Page 2 (playing)
  C PREV SONG   D NEXT SONG        C PREV SONG   D NEXT SONG
  A PLAY        B STOP             A LOOP        B STOP

  PLAY  -> note 12, then flips to page 2 (A becomes LOOP)
  LOOP  -> note 14 (loop on/off), stays on page 2
  STOP  -> note 13 (held: also note 19), then flips to the other page
           (page 2 -> 1, and page 1 -> 2 so STOP also resyncs the pedal by hand)
  PREV / NEXT SONG -> notes 15 / 16
  NEXT SONG fires on release (Note On + Off) so holding D doesn't skip a song.

  Section mode (v1.19, Jon 2026-11-24): HOLD D to swap C/D to sections.
  Page 3 (stopped, sections)       Page 4 (playing, sections)
  C PREV SECTION D NEXT SECTION    C PREV SECTION D NEXT SECTION
  A PLAY        B STOP             A LOOP        B STOP

  PREV / NEXT SECTION -> notes 20 / 21 (map them in AbleSet)
  Hold D: page 1 -> 3, 2 -> 4, and back again, also sending CC 112 = 127
  (into section mode) or 0 (back to songs) so MAB knows the mode (v2.2). PLAY on page 3 goes to 4 and
  STOP flips 3 <-> 4, so play/stop/loop behave the same in both modes.

All notes are on channel 1: Note On on press, Note Off on release. The page
flip is a Toggle Page message that goes last and fires on release.

The presets are byte for byte those of Jon's "AbleSet Play-Loop" bank
(For Claude/Morningstar MC4 Pro/ableset_play_loop.py), which he confirmed
works. This bank adds two bank messages: CC 111 = 127 on entering the bank and
0 on leaving it. They only tell MAB the bank is showing; don't map CC 111 in
AbleSet.

Run:  python3 tools/make_bank.py      (add --check FILE to compare presets with
                                        an exported Play-Loop bank)
"""
import datetime, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "bank", "AbleSet Bridge.json")

DEVICE_MODEL = 9                      # MC4 PRO
T_CC, T_NOTE_ON, T_NOTE_OFF, T_TOGGLE_PAGE = 2, 3, 4, 14
PRESS, RELEASE, LONG_PRESS, LONG_PRESS_RELEASE = 1, 2, 3, 4
ON_ENTER_BANK, ON_EXIT_BANK = 1, 2    # bank-message events
GO_PAGE = {1: 3, 2: 4, 3: 5, 4: 6}    # Toggle Page data1 for "go to page N"
NOTE_PLAY, NOTE_STOP, NOTE_LOOP, NOTE_PREV, NOTE_NEXT, NOTE_STOP_HELD = 12, 13, 14, 15, 16, 19
NOTE_PREV_SECTION, NOTE_NEXT_SECTION = 20, 21
BANK_CC = 111
MODE_CC = 112        # hold D: 127 = section mode, 0 = song mode (tells MAB; don't map in AbleSet)
# C/D long name: a single space, so pressing PREV/NEXT shows nothing in the
# middle of the screen (Jon, 2026-11-24). An empty name might fall back to the short name.
BLANK_LONG = " "
LIME, YELLOW, WHITE, RED = 1, 4, 7, 9
# Jon's MC4 PRO shows colour numbers differently from the published chart
# (swept 2026-11-24): 14 is yellow and 13 a slightly different yellow there.
PEDAL_YELLOW, PEDAL_YELLOW_2 = 14, 13


def msg(t, data=(), action=PRESS, channel=1):
    return {"data": list(data) + [0] * (18 - len(data)), "m": 0, "c": channel,
            "t": t, "a": action, "tg": 2, "mi": ""}


def empty():
    return msg(0, action=0)


def fill(msgs):
    msgs = msgs + [empty() for _ in range(32 - len(msgs))]
    for i, m in enumerate(msgs):
        m["m"] = i
    return msgs


def note(n, held=False):
    """Note On on press, Note Off (velocity 127, as on Jon's MC6) on release."""
    return [msg(T_NOTE_ON, [n, 127], LONG_PRESS if held else PRESS),
            msg(T_NOTE_OFF, [n, 0 if held else 127], LONG_PRESS_RELEASE if held else RELEASE)]


def preset(num, short, long, led, bg, msgs, name=0, toggle=False, toggle_name="",
           led_toggle=0, group=0, is_exp=False, shift=("", 0), toggle_bg=0, toggle_name_colour=WHITE):
    return {
        "presetNum": num, "bankNum": 0, "isExp": is_exp,
        "shortName": short, "toggleName": toggle_name, "longName": long, "shiftName": shift[0],
        "toToggle": toggle, "toBlink": False, "toMsgScroll": False, "toggleGroup": group,
        "ledColor": led, "ledToggleColor": led_toggle, "ledShiftColor": 0,
        "nameColor": name, "nameToggleColor": toggle_name_colour, "nameShiftColor": WHITE,
        "backgroundColor": bg, "toggleBackgroundColor": toggle_bg, "shiftBackgroundColor": shift[1],
        "msgArray": fill(msgs),
    }


def flip(page):
    return msg(T_TOGGLE_PAGE, [GO_PAGE[page]], RELEASE)


def tap_on_release(n):
    """Note On + Note Off both on release: a hold (long press) sends nothing."""
    return [msg(T_NOTE_ON, [n, 127], RELEASE), msg(T_NOTE_OFF, [n, 127], RELEASE)]


def hold_flip(page, to_sections):
    """Hold D: change page and tell MAB which mode the pedal is now in."""
    return [msg(T_CC, [MODE_CC, 127 if to_sections else 0], LONG_PRESS),
            msg(T_TOGGLE_PAGE, [GO_PAGE[page]], LONG_PRESS)]


presets = []
for page in (1, 2, 3, 4):
    o = (page - 1) * 4
    playing = page % 2 == 0
    sections = page >= 3
    other = page - 1 if playing else page + 1          # PLAY / STOP stay in the same mode
    swap = page - 2 if sections else page + 2          # hold D: songs <-> sections
    if playing:
        presets.append(preset(o, "LOOP ON", "LOOP ON", PEDAL_YELLOW, PEDAL_YELLOW, note(NOTE_LOOP),
                              toggle=True, toggle_name="LOOP OFF", led_toggle=PEDAL_YELLOW_2, group=1,
                              toggle_bg=PEDAL_YELLOW_2, toggle_name_colour=0))
    else:
        presets.append(preset(o, "PLAY", "Play -> C0", LIME, LIME, note(NOTE_PLAY) + [flip(other)]))
    presets.append(preset(o + 1, "STOP", "STOP -> C#0", RED, RED,
                          note(NOTE_STOP) + note(NOTE_STOP_HELD, held=True) + [flip(other)]))
    if sections:
        presets.append(preset(o + 2, "PREV SECTION", BLANK_LONG, WHITE, 124, note(NOTE_PREV_SECTION), name=WHITE))
        presets.append(preset(o + 3, "NEXT SECTION", BLANK_LONG, WHITE, 27,
                              tap_on_release(NOTE_NEXT_SECTION) + hold_flip(swap, False), name=WHITE))
    else:
        presets.append(preset(o + 2, "PREV SONG", BLANK_LONG, WHITE, 124, note(NOTE_PREV), name=WHITE,
                              shift=("MOVE UP", 60)))      # shift labels left over from the MC6 bank
        presets.append(preset(o + 3, "NEXT SONG", BLANK_LONG, WHITE, 27,
                              tap_on_release(NOTE_NEXT) + hold_flip(swap, True), name=WHITE,
                              shift=("MOVE DOWN", 13)))

bank = {
    "bankNumber": 0, "bankName": "AbleSet Bridge", "bankClearToggle": False,
    "bankMsgArray": fill([msg(T_CC, [BANK_CC, 127], ON_ENTER_BANK),
                          msg(T_CC, [BANK_CC, 0], ON_EXIT_BANK)]),
    "presetArray": presets,
    "expPresetArray": [preset(i, "EMPTY", "", 0, 0, [], name=WHITE, is_exp=True) for i in range(2)],
    "bankDescription": "AbleSet transport (PLAY becomes LOOP while playing; hold D for sections); MorningstarAblesetBridge shows song names",
    "toDisplay": False, "pageLimit": 0, "backgroundColor": 127, "textColor": 127, "isColorEnabled": True,
}


def js_hash(text):
    """The editor's file hash: h = (h<<5) - h + charCode, signed 32 bits."""
    h = 0
    for ch in text:
        h = ((h << 5) - h + ord(ch)) & 0xFFFFFFFF
    return h - 0x100000000 if h >= 0x80000000 else h


data = {"bank": bank}
backup = {
    "schemaVersion": 1, "dumpType": "singleBank", "deviceModel": DEVICE_MODEL,
    "downloadDate": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
    "hash": js_hash(json.dumps(data, separators=(",", ":"), ensure_ascii=False)),
    "data": data,
    "description": "MC4 PRO AbleSet Bridge",
}

if "--check" in sys.argv:
    with open(sys.argv[sys.argv.index("--check") + 1]) as f:
        ref = json.load(f)["data"]["bank"]["presetArray"]
    # Pages 1-2 against the Play-Loop bank. Deliberate changes: C/D long names
    # blank, LOOP's pedal-tested yellows, and D (tap on release + hold = section mode).
    diffs = [(p["presetNum"], k) for p, r in zip(presets[:8], ref[:8]) for k in p
             if p[k] != r.get(k) and not (k == "longName" and p["presetNum"] % 4 in (2, 3))
             and not (p["presetNum"] % 8 == 4 and "olor" in k)
             and not (p["presetNum"] % 4 == 3 and k == "msgArray")]
    print("presets identical to the reference" if not diffs else "differences: %s" % diffs)
    sys.exit(1 if diffs else 0)

with open(OUT, "w") as f:
    json.dump(backup, f, separators=(",", ":"), ensure_ascii=False)
print("wrote", OUT)
