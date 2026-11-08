# PhoneCam plan

Goal: Pixel camera appears as "Phone Camera" in macOS meeting apps over local Wi-Fi, no OBS.

## Milestones (build order)
1. **Synthetic frames through the camera extension in a real consumer.** Extension built; app feeds test pattern/placeholder via sink. Accept: `camcheck` lists Phone Camera and sees changing frames; one meeting app shows it.
2. **Android video reaches the Mac preview over Wi-Fi.** Accept: Mac preview shows live phone video; stats show resolution/fps.
3. **Received video feeds the virtual camera.** Accept: meeting app shows live phone video, upright, correct aspect.
4. **Pairing, disconnect, reconnect.** Accept: QR pairing; invalid/expired/reused tokens rejected; Wi-Fi drop → placeholder within ~1 s → auto-recovery; Forget on Mac forces re-pair.
5. **Controls, install, long-call stability.** Accept: start/stop, camera/lens switching from phone and Mac, 30+ min session with stats logged.

## Acceptance criteria
| # | Requirement | How verified |
|---|---|---|
| A1 | 1080p30 target, 720p fallback | CameraX resolution selector; Mac stats.csv width/height/fps |
| A2 | Front/rear + lenses (0.5×/1×/tele) | Phone + Mac pickers; frames change |
| A3 | Correct orientation and aspect | Compositor unit test + snapshots in portrait/landscape |
| A4 | Mac preview, status, start/stop | Menu UI |
| A5 | QR pairing, expiring single-use token | Unit + loopback server tests; on-device pairing |
| A6 | LAN only, no cloud/accounts | Empty ICE servers; code review |
| A7 | Reconnect after interruption | Wi-Fi toggle on phone; stats.csv timeline |
| A8 | Explicit re-pair on revoke | Forget on Mac → phone shows "Pair again" |
| A9 | Placeholder, never stale | Extension 1 s timeout; app state placeholders |
| A10 | Mac mic only, no phone audio | No audio tracks on either side |
| A11 | No OBS/DAL/private API/SIP bypass | Code review |
| A12 | Actionable errors | Extension activation, signing, firewall/network, permissions |
| A13 | Real meeting app + sustained session | Physical device + installed app (Teams/FaceTime/Chrome Meet) |
| A14 | Camera runs only while used | Extension consumer count → Mac start/idle; phone Ready ↔ live (camcheck open/close) |
| A15 | LAN-only enforced, pairing confirmed | Private-address checks both sides (unit tests); phone confirmation dialog |
