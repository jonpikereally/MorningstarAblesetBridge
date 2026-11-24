# MorningstarAblesetBridge error codes

**Getting help from an AI assistant:** in MorningstarAblesetBridge, click the ⚠️ Problem row, press **Copy Error Details**, and paste that into the assistant together with a link to this page.

Every error MorningstarAblesetBridge shows has a code. Codes are never reused.

| Code | What happened | What to try |
|---|---|---|
| MAB-201 | Couldn't open a network socket to talk to AbleSet. | Quit and reopen MorningstarAblesetBridge. If it keeps happening, restart the Mac. |
| MAB-202 | MorningstarAblesetBridge's OSC listening port is already used by another app. | Quit any other copy of MorningstarAblesetBridge (Ableton Live itself uses 39061), or pick another listening port: defaults write com.jonpike.morningstarablesetbridge listenPort -int 39162, then reopen MorningstarAblesetBridge. |
| MAB-203 | AbleSet isn't answering over OSC. | Open AbleSet and make sure it's running on this Mac (OSC port 39051). MorningstarAblesetBridge keeps retrying every few seconds. |
| MAB-204 | The AbleSet host address isn't a valid IP address. | Reset it: defaults delete com.jonpike.morningstarablesetbridge ableSetHost, then reopen MorningstarAblesetBridge. |
| MAB-301 | Couldn't start CoreMIDI. | Quit and reopen MorningstarAblesetBridge. If it keeps happening, restart the Mac. |
| MAB-302 | The MC4 PRO isn't connected to this Mac over MIDI. | Connect the MC4 over Bluetooth (Audio MIDI Setup → MIDI Studio → Bluetooth) or USB. Bluetooth only reaches one host, so disconnect it from the iPad first. |
| MAB-303 | Sending a message to the MC4 PRO failed. | Reconnect the MC4 (Bluetooth or USB) and choose “Resend Everything to Pedal”. If it keeps happening, power-cycle the pedal. |
| MAB-304 | The MC4 PRO isn't answering MorningstarAblesetBridge's questions. | Reconnect the MC4 (Bluetooth or USB) and choose “Resend Everything to Pedal”. If it keeps happening, power-cycle the pedal. |
| MAB-305 | The MC4 PRO rejected a message from MorningstarAblesetBridge. | Note the details (Copy Error Details) — the pedal's firmware may expect a different message layout. |
| MAB-999 | Something unexpected went wrong. | Quit and reopen MorningstarAblesetBridge. If it keeps happening, copy the details and ask for help. |
| MAB-601 | install.sh couldn't copy MorningstarAblesetBridge into ~/Applications. | Check ~/Applications exists and isn't locked, then run ./install.sh again. |
| MAB-602 | install.sh couldn't sign MorningstarAblesetBridge. | Run ./install.sh again; if it repeats, run `xattr -cr ~/Applications/MorningstarAblesetBridge.app` first. |
| MAB-603 | MorningstarAblesetBridge installed but couldn't be opened. | Open it from ~/Applications yourself. |
