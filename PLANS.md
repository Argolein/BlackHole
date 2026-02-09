# PLANS.md

## Objective
Implement and ship sample-rate lock control for BlackHole with:
- driver-side enforcement (block sample-rate changes while lock is enabled),
- CLI control surface,
- menu bar app toggle UX,
- documentation and repeatable build steps.

## Open questions
- Should the lock state remain file-based (`/tmp/blackhole_sample_rate_lock_state`) long-term, or be migrated to a persistent + permission-scoped config location?
- Should `blackholectl` be installed system-wide by installer (`/usr/local/bin` or `/opt/homebrew/bin`) in a follow-up PR?
- Should the menu bar app include launch-at-login and explicit device picker UI in a follow-up PR?

## Approved plan
- Enforce lock in `BlackHole/BlackHole.c` for both device nominal sample rate and stream physical/virtual format paths.
- Use a shared lock-state file (`/tmp/blackhole_sample_rate_lock_state`) read by driver during rate-change checks.
- Provide `blackholectl` CLI source + build script in `Tools/`.
- Provide lightweight menu bar app (`BlackHoleLockMenuBar`) + build script in `Tools/`.
- Document CLI and menu bar app usage in `README.md`.
- Ignore generated local artifacts in `.gitignore`.

## Implementation status
- [ ] Not started
- [ ] In progress
- [x] Done

## Decisions
- Driver enforcement is active in `BlackHole/BlackHole.c`:
  - lock check in device sample-rate set path,
  - lock check in stream format set path,
  - lock check in perform configuration change.
- Runtime lock state source of truth is `/tmp/blackhole_sample_rate_lock_state` with format:
  - `0 0.000000` (lock off),
  - `1 <locked_rate>` (lock on).
- CLI controls lock by writing the lock-state file and reading device sample rate via CoreAudio:
  - `blackholectl lock on|off|status`
  - optional `--device-uid <uid>`
- Menu bar app uses same lock-state file as CLI and shows BlackHole icon in status bar.
- Keep both `/Library/Audio/Plug-Ins/HAL/BlackHole.driver` and `/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver` aligned to avoid loading mismatched binaries.

## Notes
- Key files:
  - `BlackHole/BlackHole.c`
  - `Tools/blackholectl.swift`
  - `Tools/build_blackholectl.sh`
  - `Tools/BlackHoleLockMenuBar/main.swift`
  - `Tools/BlackHoleLockMenuBar/Info.plist`
  - `Tools/build_blackhole_lock_menubar_app.sh`
  - `README.md`
- Build commands:
  - Driver: `xcodebuild -project BlackHole.xcodeproj -scheme BlackHole -configuration Release -derivedDataPath /tmp/BlackHoleDerived CODE_SIGNING_ALLOWED=NO build`
  - CLI: `Tools/build_blackholectl.sh`
  - Menu bar app: `Tools/build_blackhole_lock_menubar_app.sh`
- Install commands (manual, requires sudo):
  - `sudo cp -R /tmp/BlackHoleDerived/Build/Products/Release/BlackHole.driver /Library/Audio/Plug-Ins/HAL/BlackHole.driver`
  - `sudo cp -R /tmp/BlackHoleDerived/Build/Products/Release/BlackHole.driver /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver`
  - `sudo killall -9 coreaudiod`
- Verified behavior:
  - Lock OFF: sample-rate changes succeed.
  - Lock ON: rate changes rejected (`kAudioHardwareIllegalOperationError`).
  - Lock OFF again: sample-rate changes succeed.
