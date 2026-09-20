# NUEM Essential

A quiet, desktop-only fork of [NUEM](https://github.com/tgtools123/NUEM). The classic screen fold follows your MacBook lid, with the original visual tuning fixed in code.

Five switches:

- Enable the fold effect.
- Adjust to your resting lid angle.
- Fade the pointer during the fold.
- Show or hide the menu bar icon.
- Open at login.

If you hide the icon, open **NUEM Essential** again from Spotlight or Applications to reach settings. Settings appear on the first launch. Preview Effect plays a close/open cycle without moving the lid.

There are no sounds, haptics, snap animations, alternate styles, tuning editors, presets, keyboard-light controls, lock-screen effects, external-display controls, or sleep overrides.

## Build and run

Requires macOS 14 or later, a MacBook lid angle sensor, and Xcode Command Line Tools.

```sh
git clone https://github.com/me93-ghb/NUEM-Essential.git
cd NUEM-Essential
./build.sh run
```

`./build.sh` builds into `build/NUEM-Essential.app`. `./build.sh install` replaces an existing Essential installation in `/Applications` and launches it. Quit the original NUEM before using this fork so two effects do not compete.

The build uses this Mac's architecture. Set `ARCHS="arm64 x86_64"` for a universal binary. The app is signed locally with an ad-hoc identity by default, not notarized by Apple.

Allow the app in **System Settings > Privacy & Security > Screen & System Audio Recording**, then relaunch if requested. This fork has its own app identifier and permission entry. It takes still screen images; it does not capture system audio or microphone input.

## Behavior and privacy

The effect uses an in-memory snapshot of the built-in display. It releases the snapshot when the effect stops and on lock, sleep, or display changes. Pending captures are invalidated at those transitions. It does not save screenshots or include a network client.

The effect is disabled on locked or inactive sessions and while the built-in display is mirrored. Opening from sleep may show no animation until the desktop is unlocked and the lid moves. Sleep settings are left to macOS.

Pointer fading uses a private macOS cursor API inherited from NUEM. If unavailable, the real pointer remains visible. The application is not sandboxed; Screen Recording is a sensitive permission.

The classic projection, blur, darkening, fixed curves, and angle smoothing come from NUEM. The desktop capture lifecycle and settings window are simplified. Exact perspective and its model-specific hinge calibration controls are removed; the classic lift retains the upstream geometry.

## Checks

```sh
./test.sh
```

The check runs fixed-curve and lid-smoothing checks and renders synthetic images through Metal. It does not capture your screen. Running requires Metal access outside a restrictive sandbox.

## Credits and license

By TGTools123. NUEM Essential is a modified fork, not an official NUEM release. Modified files identify changes made on 2026-09-20.

GNU GPL v3 with the upstream attribution terms in [NOTICE](NOTICE). See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). These files are also included in the application bundle.
