# PhoneCam status

_Last updated 2026-10-17 (session 1). Read PLAN.md first._

## Current blockers (need the owner)
1. **New phone app installed, not yet verified on the phone.** The review-fix APK (`android/app/build/outputs/apk/debug/app-debug.apk`, built 2026-10-17 13:48, unit tests 21/21) was installed on the Pixel 6 Pro at 09:58 on 2026-10-25 (adb package install time; installed, not run-tested). The owner confirmed on 2026-10-25 that the 6 Pro is the PhoneCam phone (the one he also calls the "Pixel 8"). The Mac is backward compatible, and the pairing should survive the update.
   Still unverified on the phone: camera off when idle, `bye`/`replaced` handling, pairing confirmation, LAN-address validation. Also uploaded to cloud storage (file name omitted here).
   Action: run the "Exact next action" checks below.

## Exact next action
After the APK is on the Pixel: open a consumer (`/tmp/pc/camcheck 10` or a meeting app) and confirm the phone goes Ready → live → Ready (10 s after the consumer closes); tap Stop on the phone and confirm the Mac shows "Stopped on phone"; run `mac/scripts/soak.py 30` with a meeting app holding Phone Camera (or `PhoneCamAlwaysOn`), with the screen on for 10 min then off for 10 min; toggle phone Wi-Fi once mid-run.

## Live indicator torch (2026-10-25)
- Phone setting "Light while live" (off by default) + brightness slider: the back flash lights only while video is live on a Mac and turns off when the Mac drops to standby or the camera stops.
- Back camera streaming: torch through the capture session (CameraX `enableTorch`); strength via `FLASH_STRENGTH_LEVEL` only on Android 15+ (not testable here). On Android 14 it runs at the phone's default flashlight brightness and the UI says so. Front camera streaming: `CameraManager.turnOnTorchWithStrengthLevel` on the back flash (dimmable, Android 13+).
- Verified on the physical Pixel 6 Pro (raven, Android 14, flash 45 levels, default 21) with `build/camcheck`: back-uw → camera flash state TORCH while live, torch off at 10:00:01, 2 s after the Mac logged live→standby; front → `Torch strength for camera id 0 changed to 3`, off 18 s later with standby. The torch follows the Mac's live state, which stays live ~20 s after the last consumer closes.
- Not verified: the new switch/slider UI on screen (phone was locked; setting was enabled through prefs), and the Android 15 in-session brightness path.


### Light on/off from the Mac and the notification (2026-10-26)
- Protocol: phone `state` carries `torch` (the "Light while live" setting; omitted when the phone has no flash); Mac sends `control` `action:"torch"` + `torch:Bool`. Older phones ignore it, so the Mac hides the toggle when `torch` is absent.
- Mac menu: "Phone light while live" switch under the lens picker (`Views.swift`, `AppModel.setTorch`). Phone: "Light off/on" button in the PhoneCam notification (`StreamService.ACTION_TORCH`), plus the existing in-app switch. All three change the same saved setting.
- Built and tested: Gradle unit tests + assembleDebug, `swift test` (35/35), Mac Debug build. Mac app installed to /Applications 2026-10-26 08:27 (build 202610260827).
- Verified on the Pixel 6 Pro (APK installed 2026-10-26 09:44 after the Mac restart): the in-app "Light while live" switch and the Android 14 note render (screenshot); the notification shows "Light off"/"Light on", and three real taps flipped the saved `torch` false→true→false→true with the label following. Setting left on.
- Verified 2026-10-26: the Mac menu switch turned the phone light off (saved setting true → false at 09:54:21, the owner confirmed he flipped it from the Mac). The off→on direction from the Mac was not separately observed; it uses the same message path.
- That install also replaced the camera extension (its sources changed 2026-10-22 18:37, after the installed 202610221059). Phone Camera was missing until the Mac restarted; after the owner's restart on 2026-10-26 the Mac is back to standby with the sink connected.
### Picture colour check (2026-10-26)
- Measured on the Pixel 6 Pro → Mac Studio: the phone's encoder (c2.exynos.h264.encoder, logcat) is configured BT.709, limited range, SDR transfer (color-standard=1, color-range=2, color-transfer=3). The Mac decodes to `420f` tagged matrix/primaries/transfer = 709 (new `decoded frames:` log line in VideoPipeline), and CoreImage honours those tags when compositing to sRGB BGRA. The colour chain is already consistent; no colour change was made. A side-by-side visual check against the phone preview was not possible (phone locked).
- install.sh bug fixed: the extension source hash depended on the shell locale (`sort -z` order differs between C.UTF-8 and en_US.UTF-8), so the 12:59 install replaced the camera extension (now 0.1.0/202610261259) with no source change, and Phone Camera is missing until the Mac restarts (app asked for a restart at 13:00:33). Hash now computed with LC_ALL=C; the stored hash already matches it.
- Seen, not diagnosed: at 13:01:38 (when the phone screen was woken over adb) Mac ICE went disconnected → failed at 13:01:53 and the Mac stayed "connecting" while the phone logged a new peer CONNECTED. Belongs to the reliability checks.


### Frame rate: thermal step-down (2026-10-26)
- Baseline (home Studio stats.csv, 12:28-13:04, old APK, battery 100%, likely charging): 1080p30 for 13 min → "warm" 720p30 at 12:41 → "hot" 720p **24 fps** from 12:48 to the end (16 min, never recovered). Bitrate sat at the 6 Mbps cap throughout, so Wi-Fi was not the limit.
- Cause found: the live capture request had `videoStabilizationMode ON` (implied by CONTROL_CAPTURE_INTENT_VIDEO_RECORD; `dumpsys media.camera`). Fix d532a4a: EIS off (OIS stays), 3.5 Mbps cap at 720p, capture at the encoder rate (24) when severe.
- Verified on the Pixel 6 Pro (APK installed 14:27): live request shows `videoStabilizationMode OFF`. 32-min soak 14:30-15:02 (`docs/soak-2026-10-26-stab-off.csv`), continuous 30 fps capture (~915 frames/30 s): thermal LIGHT for 23 min, MODERATE (720p30) 14:53-14:59, back to LIGHT and 1080p at 14:59; never SEVERE, never 24 fps. Big cores 55-60 °C, battery 36-37.7 °C.
- Caveats: the soak phone was unplugged at 56% → 45%; the baseline was at 100%, probably on the charger, which adds heat. The stream went to a second Mac from 14:43 to 15:00 (home Studio showed "connecting"), which doesn't change the phone-side numbers. A charging run is still needed for a like-for-like comparison.

## Multi-Mac check (needs the owner, ~5 min, both Studios + the Pixel 6 Pro)
Not yet run on hardware. Steps: see the `multi-mac` PR description ("Morning test"). Record the result in the "Several Macs per phone" row.

## Requirement tracker
States: **verified** (observed, evidence below) · **implemented** (built, not yet observed end to end) · **blocked**.

| Req | State | Evidence / gap |
|---|---|---|
| Mac app, extension, Android compile | verified | `xcodebuild` Debug+Release succeed (ad hoc); `./gradlew assembleDebug` succeeds |
| Core unit tests | verified (2026-10-17 14:00) | `swift test`: 35/35, three consecutive runs (pairing, tokens, loopback signaling incl. `replaced` notice and storage failure, compositor, SDP, Keychain merge, LAN filter, frame slot, camera demand, shared protocol vectors). Kotlin 21/21 (crypto 4, protocol/LAN 7, shared vectors 5, quality policy 5). Both suites read `docs/protocol-vectors.json` |
| Android video → Mac preview over network | verified (physical Pixel 8, 2026-10-17 11:03) | The owner's screenshot: Live, 1920×1080 · 30 fps · **H264** · 22 ms RTT over Wi-Fi; Mac log 180 frames/6 s decoded, 0 dropped; PhoneCam CPU 19%, RSS 147 MB. Earlier emulator: Android 15 emulator → Mac over NAT/LAN: live 30 fps, RTT ~1 ms, jitter buffer ~16-19 ms |
| 1080p30 / 720p fallback | verified (emulator) | Front emulated camera 1920×1080 @ 30; back virtual scene 1280×720 @ 30 (its max). Physical Pixel untested |
| Orientation + aspect | verified (emulator, back camera) | Portrait → upright pillarbox; landscape → upright full 16:9 (frame snapshots). Front-camera orientation needs a physical device |
| Camera/lens switching | verified (emulator) | Back 1× ↔ Front from the phone UI and from the Mac (control message → phone opens camera 1 / 10). 0.5×/tele presets need a physical Pixel |
| Pairing: valid / reused / expired / invalid tokens | verified | Loopback server tests for all four; on emulator: pairing succeeds, replayed code → `token_used` (trusted phone falls back to its pairing), code used after 130 s → `token_expired` |
| Reconnect after interruption | verified (emulator) | Wi-Fi off 8-10 s → Mac placeholder "Reconnecting" ≤1 s → live again 1280×720@30 ~6 s after Wi-Fi returns. Mac app restart → phone reconnects automatically |
| Revoke → explicit re-pair | verified (emulator) | Forget on Mac → sealed `revoked` → phone deletes macId/secret (checked in its prefs), shows "Pair again"; re-pair with new code → live |
| Placeholder, never stale | verified (2026-10-17 14:04) | App: placeholder within 0.5 s of last frame. Extension: `kill -9 PhoneCam` during a camcheck run → camcheck snapshot shows the extension's own "Open PhoneCam on your Mac" frame |
| Start/stop from Mac | verified (emulator) | Stop → phone camera off, "Paused from the Mac" placeholder; Start → live 1080p30 |
| Screen lock / background | verified (emulator) | Screen asleep 30 s and Home pressed: stream stayed 1080p30; FGS type camera active |
| Virtual camera enumerates + live frames | verified (2026-10-17 14:03, pass-through extension) | Extension 0.1.0/202610171402 forwards frames as they arrive: `camcheck 10` → 299 frames @ 29.9 fps, 299 distinct, snapshot = live Pixel 8 image. Consumer count read by the app (0 → 1 → 0) switched the Mac from standby to live and back. First verified 11:28 with the timer-based extension (300/300) |
| Meeting app test | verified by the owner (2026-10-17 ~11:35) | The owner confirmed live phone video works in the meeting app after the sink fix (FaceTime 36 / Teams 26106.2113.4690.1073 tested by the owner; which app(s) not specified). Agent could not view the screen |
| Sustained session | verified (emulator, 30 min); physical attempt invalid | Emulator 14:12-14:42Z: 898/900 samples live. Physical attempt 17:20-17:50Z (soak.py): only 1 of 900 samples live (the Mac was in `paused` for the rest, likely the old Space shortcut toggling Stop, since removed), so it proves nothing. Needs a rerun with the new APK |
| Mac sleep/wake | implemented, untested | Listener restart + phone reconnect path; not exercised (shared machine) |
| Incoming call / camera taken by other app | implemented, untested | CameraX state → "Camera in use by another app" note + placeholder |
| LAN only, no cloud, no phone audio | implemented + unit-tested; Mac side live | Empty ICE server lists; no RECORD_AUDIO. Now enforced: Mac refuses non-private peers and VPN/cellular interfaces, filters candidates/SDP both ways, Bonjour only while paired; phone rejects non-RFC1918 pairing hosts and off-LAN candidates (phone side not yet on a device) |
| Camera on demand | Mac verified, phone implemented | Mac: extension consumer count drives start/idle with a 10 s off delay (verified with camcheck). Old phones are kept streaming (they ignore `idle`). Phone side (camera off until `start`) needs the new APK |
| Installed build | verified (2026-10-17 14:14) | /Applications/PhoneCam.app + extension 0.1.0/202610171413, team <TEAM_ID>. Update cycle ran unattended (update 14:13:24 → repair 14:13:34 → relaunch 14:13:42 → sink connected); old-APK Pixel shows live; camcheck 299/299 distinct @ 30 fps |
| Several Macs per phone | implemented + unit-tested (2026-11-04); two-Mac handover not verified on hardware | Phone keeps a link to every paired Mac; CameraArbiter gives the camera to the first Mac that asks, hands it to the longest-waiting Mac when released, "Use here" (phone) and "Use on this Mac" (Mac menu, control `takeover`) move it and queue the previous owner first. Mac shows "Camera in use on X" (menu) / "In use on other Mac" (placeholder) from `state.busy`; that logic lives in `PhoneCamCore.CameraHandover` (8 Swift tests incl. the phone's wire format). Phone trusted-Mac list rules in `MacList` (6 tests; re-pairing now replaces the entry in place). Arbiter 10 tests. Kotlin 37/37, Swift 43/43, Android assembleDebug + Mac Debug/Release builds pass (branch `multi-mac`, 2026-11-04). The phone has run multi-Mac builds since the 2026-10-26 installs (built from main after 6d9687e/8e0a914); on 2026-10-26 the stream went to the second Mac 14:43-15:00 while the home Studio showed "connecting" (seen in stats, not a deliberate handover test). The `multi-mac` branch builds are **not installed** anywhere; the deliberate two-Mac check is the morning test in the PR / "Multi-Mac check" below |
| Extension version pinning | implemented 2026-10-22 | install.sh bumps the camera extension's CFBundleVersion only when its sources change (build/ext-version), because each replacement can leave Phone Camera missing until a restart (seen on both Studios with 202610221059: old copy "terminated waiting to uninstall on reboot", registerassistantservice logging "Invalid process identifier"; `sudo killall` of that service did not restart it). Menu now says "Restart this Mac…" when re-activate + relaunch didn't bring the device back |
| Keychain re-auth | verified (2026-10-17 13:55) | Pixel 8 reconnected by itself to the Keychain-only Mac store ("keychain store: 1 trusted phone(s)", video track received) |
| Actionable errors | implemented | Extension preflight (/Applications, team signature), OSSystemExtension error mapping, phone network/firewall message after 2 failed rounds |

## Phone microphone, per Mac (2026-10-27)
| Requirement | Status | Evidence |
|---|---|---|
| Camera and mic chosen separately per Mac | implemented + verified on the home Studio | Menu switch "Phone microphone" (per Mac, `PhoneMicEnabled`). On: installs `PhoneCamMic.driver` into /Library/Audio/Plug-Ins/HAL (admin prompt, restarts coreaudiod) and adds an input "PhoneCam Mic"; meeting apps pick it independently of Phone Camera. Off: removes the driver; the Mac never asks the phone for audio. second Mac: leave it off and use the Yeti (nothing installed there). |
| Phone sends mic only to Macs that ask | implemented + verified (Pixel 6 Pro) | `start` control carries `mic`; the phone adds an Opus track (same stream id as the video) only then. FGS types 0xC0 (camera + microphone) after the permission. Recording runs only while a peer with audio exists. |
| Mac receives audio without playing it | verified | Custom `RTCAudioDevice` (`PhoneMicTap`, header copied from libwebrtc since the macOS framework omits it) pulls 10 ms of 48 kHz mono and sends it over loopback UDP 127.0.0.1:47801 to the driver (~20 ms buffer). |
| Driver delivers audio to apps | verified 2026-10-27 12:53 | Raw IOProc: ~48 000 frames/s, 89% non-zero. AVFoundation (`build/miccheck`): 48 128 frames/s; speech from the Mac Studio speakers −45 dBFS vs room −70 to −80 dBFS. Recording from PhoneCam Mic alone turned the phone live (mic counts as demand). Not yet tested in Zoom/Teams/Meet, or with the owner speaking at the phone. |
| Lip sync, phone mic | verified 2026-10-27 13:05 | `LATENCY_AUDIO=Speakers build/latency 20` (flash + 2 kHz beep per flip): video median 231 ms, PhoneCam Mic audio median 202 ms; video trails audio by median 36 ms, ~15 ms over the last 10 flips once WebRTC's A/V sync had ramped the audio delay (160 → 230 ms). With the Yeti / Mac mic the video still trails by ~220 ms. |
| Known limits | — | An app using only PhoneCam Mic still turns the phone camera on. Loopback UDP is unauthenticated (any local process could feed the mic). The driver gets a new version (and an "Update…" prompt) only when `mac/PhoneCamMic` changes. Latency figure in the flash test is face-region based now; a bright room needs the face lit by the monitor. |

## Lip sync phase 2: where the video delay goes (2026-10-27, Pixel 6 Pro → home Studio, 1080p30)
- Glass-to-glass 231 ms median (14 flips, face-region flash test). Measured parts: phone H.264 encode ~20 ms/frame (outbound-rtp totalEncodeTime, logcat "latency:" line), network + jitter buffer ~30 ms, decode ~3 ms, extension sink poll ≤17 ms (60 Hz, avg ~8), display output ~10-20 ms. That leaves **~130 ms in the phone camera pipeline** (sensor → SurfaceTexture). The capture-age figure in the log (5-14 ms) is not sensor time and should be ignored.
- Tried, no gain (A/B with the same tool, minutes apart): CONTROL_CAPTURE_INTENT_PREVIEW 252 ms; PREVIEW + NOISE_REDUCTION/EDGE FAST 243 ms; default (VIDEO_RECORD) 231 ms. Kept the default. Experiment switch stays in code (pref `latencyMode`, unset = default).
- Tried, not effective yet: 60 fps camera with 30 fps encode (pref `captureFps60`): the phone still delivered 30 fps (CameraX's Preview target range isn't honoured as asked; needs the supported ranges checked). Pref removed from the phone again. Not measured.
- Not worth it now: extension sink polling (would need an extension replacement, which has needed a restart).
- Next: make 60 fps capture actually run (check `CameraInfo.getSupportedFrameRateRanges`), then re-measure; this is the only lever left that targets the ~130 ms. Flash tests need the ultra-wide monitor on (a Jump Desktop-only session has no physical display).

## Measurements (emulator, Mac Studio, Release build)
- 30-min run: Mac CPU median 23% (max 33%); RSS 183 → ~250 MB, flat for the last ~12 min (plateau, not runaway; re-check on a longer hardware run). Second-half fps/resolution wandered (640-1280, 21-27 fps) as WebRTC adapted to the emulator's software VP8 encoder.
- Mac app CPU 13-28% at 720p-1080p **VP8** (software decode; emulator has no H.264 encoder). RSS ~110-130 MB. Physical Pixel should negotiate H.264 → VideoToolbox.
- Glass-to-glass latency: not measured (needs physical camera + display). Network RTT 1 ms; receiver jitter buffer 16-19 ms; decode 1.2-1.6 ms/frame.
- **Glass-to-glass latency, Pixel 6 Pro → home Studio (2026-10-27 12:17, physical):** median **208 ms**, p90 245 ms, min 193 ms, max 255 ms over 20/20 screen flips (`mac/scripts/latency.swift`: flashes the display, times the change in frames an AVFoundation consumer receives from Phone Camera; includes the display's own output latency, so slightly high). Stream 1080p30 H.264 ~6 Mbps; stats.csv at the time: jitter buffer ~28.5 ms, RTT 3-9 ms, decode 2.6 ms. So only ~35 ms is network + jitter buffer + decode; the other ~170 ms is on the phone (exposure, ISP, CameraX → encoder) and the Mac compositor/extension/consumer, not yet split. Well over the 100 ms bar: video trails the Mac mic by about 0.2 s in meetings. The owner chose (2026-10-27) to measure before deciding on phone audio; next is phase 2 (cut the delay), then decide on the virtual mic (Mac mic delayed, phone mic as an optional second source).

## Security review (independent lens-reviewer, 2026-10-17) and fixes
- Fixed: unauthenticated `error` frames (e.g. a spoofed Bonjour service) could make the phone delete its pairing. Now only a **sealed** `revoked` deletes it; pre-auth rejections show "Pair again" but keep retrying every 10 s. Known addresses are tried before Bonjour results.
- Fixed: 3 junk attempts burned each QR code (pairing DoS). Removed the global burn counter (tokens are 128-bit); a new code isn't minted on every rejection.
- Fixed: 8 idle sockets could fill the server. Now 16 slots, oldest unauthenticated connection evicted, ≤3 unauthenticated per address, 5 s pre-auth timeout.
- Fixed: phone took `macId` from the unauthenticated `paired` reply; now uses the QR code's. Nonces must be exactly 16 bytes. After auth, liveness counts only sealed traffic (Mac answers pings with sealed pongs).
- Done 2026-10-17: Mac secrets moved to the data-protection Keychain (migration verified live: "migrated 1 trusted phone(s)", file removed; after relaunch "keychain store: 1 trusted phone(s)"). Phone re-auth against the Keychain copy not yet observed (phone wasn't connecting at the time).
- Open hardening: one key for pair proof + seal (split with HKDF; changes test vectors); deviceName not bound into the pair proof.

## Adversarial review (5 lenses, 2026-10-17) and fixes
Reviewers: security, reliability, video quality, everyday use, code quality. The owner chose: must-fix 1-5, should-fix batch, tests + CI.
- **Link hijack (critical)**: any `phonecam://` link or app could silently re-pair the phone to a server anywhere. Fixed on the phone: confirmation dialog for every pairing, RFC1918-only hosts, off-LAN candidates dropped (unit-tested; not yet on a device).
- **Frame-drop guard never dropped**: replaced by `LatestFrameSlot` (newest frame wins, drops counted in stats `pipe_drop`); unit-tested incl. a slow-consumer load test.
- **Extension going away unnoticed**: sink health check (device gone/re-IDed, queue full > 1 s), device-list listener, reconnect after (re)activation. Live: after extension updates the app recovered by itself.
- **Extension update race (found while verifying)**: replacing a running extension made launchd refuse the new job ("Operation already in progress"), leaving no Phone Camera. Fixes: the app re-activates when the extension is active but its device is missing for 10 s; if this process still can't see the device it relaunches itself once per build. install.sh stamps a timestamp build number so every install replaces the extension, and the app auto-updates an outdated extension at launch unless the camera is in use. Verified live: update → repair → relaunch → sink connected in ~20 s.
- **Keychain**: falls back to the file only on errSecMissingEntitlement (retries other errors 10 s); merge by deviceId (newest wins) with read-back before deleting the file; failed saves now fail pairing with code `storage`.
- **Camera always on**: camera on demand (above). Phone's camera also stops 15 s after losing the Mac.
- **Sink feeder auth**: attempted signingID and code-signature checks; neither works (CMIO reports signingID "unknown"; sandbox blocks SecCodeCopyGuestWithAttributes, 100001). Shipped: one feeder at a time. Documented as a limitation.
- **Extension frame timing**: frames forwarded on arrival (no 30 Hz re-timing); a watchdog repeats the last frame if the app is late and shows the placeholder after 1 s. Sink queue 3 → 2.
- **Two phones fighting**: sealed `replaced` notice; the replaced phone stops retrying (loopback test).
- **Bitrate/quality**: 6 Mbps cap, 600 kbps floor, MAINTAIN_RESOLUTION, 720p step-down on BWE < 3 Mbps (backoff 30 → 300 s) or thermal ≥ moderate, 24 fps at severe (QualityPolicy unit-tested).
- **Other**: high-perf + low-latency Wi-Fi locks; continuous-video autofocus; placeholder text cut to a few words; Open at login (on after first pairing); menu icon shows needs-action; forget confirmations; Space shortcut removed; lens picker whenever connected; macOS notification when an app wants the camera and no phone is connected; `bye` → "Stopped on phone"; stats gained consumers/pipe_drop/freezes/pli/phone columns and 5 MB rotation; logs dir 0700, snapshots 0600, debug notification hooks DEBUG-only; README "burned after 3" claim and unused burn code removed; strict concurrency on (21 remaining warnings, all main-queue hops of WebRTC/CMIO objects); local CI workflow (not pushed; no remote).
- **Not done**: NV12 end-to-end pixel format and BT.709 tagging; glass-to-glass latency measurement; black-screen mode; Gradle wrapper checksum (no cached zip to hash); Android standby/screen-off/thermal behaviour on a real device.

## Activation fixes (2026-10-17)
- sysextd refused the extension: `bundle is missing CFBundleShortVersionString key` (MARKETING_VERSION was only on the app target). App had mislabeled this `validationFailed` as a signature problem; message fixed.
- App couldn't see its own CMIO device without camera TCC permission; it now requests camera access before connecting the sink.
- install.sh no longer installs a stale build when xcodebuild fails; adds -allowProvisioningDeviceRegistration.

## Decisions
- Frames app→extension via CMIO sink stream (Apple-supported); no App Groups/XPC. Extension also self-placeholders after 1 s.
- WebRTC: stasel/WebRTC 155.0.0 (Mac, BSD), io.getstream:stream-webrtc-android 1.3.10 (Apache-2.0). CameraX 1.4.1 → WebRTC SurfaceTextureHelper (zero-copy). Lenses = zoom presets on the logical camera.
- Signaling: plain ws:// on LAN, authenticated with HMACs keyed from the QR token / device secret, so DTLS fingerprints in SDP can't be swapped.
- Mac sends `x-google-start-bitrate=3000;x-google-min-bitrate=600` in its answer: without it every reconnect restarted at 320×180.
- A connection attempt is never started while another is in flight (Android `onAvailable` fires at registration and raced a single-use token).

## Camera error recovery (2026-10-26)
- Seen by the owner: the phone app stuck on "Camera error (6)". Code 6 is CameraX `ERROR_CAMERA_FATAL_ERROR`; CameraX leaves the camera CLOSED and never retries it (same for stream-config errors), and the app only displayed it.
- Change (`CameraXCapturer`): a CLOSED camera with an error, a failed bind, or an open camera with no frames for 6 s now triggers a rebind while capture is wanted. Backoff 1, 2, 4 … 30 s; it resets after 30 s open without errors. The note reads e.g. "Camera failed, restarting in 2 s" on the phone and in the Mac's state. Errors CameraX retries itself (in use, other recoverable) are left to CameraX.
- Verified: builds, unit tests pass. Installed on the Pixel 6 Pro 18:10:49 (the phone came back on a new adb port, 36993); at 18:17 it was live on a second Mac with this build, no recovery warnings logged. **The recovery path itself is not yet exercised on the phone**: I stopped before disturbing the camera because the owner was live on the second Mac. The cause of the original fatal error is unknown (it had rolled out of logcat). `PhoneCamAlwaysOn` was set briefly on the home Studio and is deleted again.
