# MorningstarAblesetBridge error codes

**Getting help from an AI assistant:** in MorningstarAblesetBridge, click the ⚠️ Problem row (or the error alert), press **Copy Error Details**, and paste that into the assistant together with a link to this page.

Every error the app, its installer or its updater shows has a code. Codes are never reused.

| Code | What happened | What to try |
|---|---|---|
| MAB-101 | No update source is set. | Set one with “Update Source…” in the menu, or leave it empty to use the built-in source. |
| MAB-102 | The update source isn't a web link or a file path. | Set one with “Update Source…” in the menu, or leave it empty to use the built-in source. |
| MAB-103 | Couldn't reach the update source. | Check your internet connection and try again. |
| MAB-104 | The update server returned an error. | Try again in a few minutes. If it keeps happening, download the latest version from GitHub. |
| MAB-105 | The update information is damaged or in the wrong format. | The published update is broken. Download the latest version from GitHub instead. |
| MAB-106 | Couldn't download the update. | Try again in a few minutes. If it keeps happening, download the latest version from GitHub. |
| MAB-107 | Couldn't unpack the downloaded update. | The published update is broken. Download the latest version from GitHub instead. |
| MAB-108 | The downloaded update doesn't contain MorningstarAblesetBridge. | The published update is broken. Download the latest version from GitHub instead. |
| MAB-109 | The downloaded update is a different app. | The published update is broken. Download the latest version from GitHub instead. |
| MAB-110 | The downloaded update is damaged. | The published update is broken. Download the latest version from GitHub instead. |
| MAB-111 | Couldn't start installing the update. | Make sure MorningstarAblesetBridge is in ~/Applications and that the folder isn't locked, then try again. |
| MAB-112 | Installing the update failed, so the previous version was kept. | Make sure MorningstarAblesetBridge is in ~/Applications and that the folder isn't locked, then try again. |
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
| MAB-601 | The installer couldn't copy the app into ~/Applications. | Check ~/Applications exists and isn't locked, then run the installer again. |
| MAB-602 | The installer couldn't sign the app for this Mac. | Run the installer again; if it repeats, run `xattr -cr ~/Applications/MorningstarAblesetBridge.app` first. |
| MAB-603 | The app was installed but couldn't be opened. | Open it from ~/Applications yourself. |
