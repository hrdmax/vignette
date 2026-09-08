# Vignette

macOS focus aid: blurs everything except the focused window.

Working name — rename freely (it appears in `project.yml`, `Resources/`, and `Makefile`).

## Install

```sh
brew install --cask maxhafs/tap/vignette
```

Vignette is signed but **not notarized** — notarization requires a paid Apple
Developer membership. macOS therefore blocks the first launch with "Apple could
not verify this app is free of malware". Approve it once:

**System Settings → Privacy & Security →** scroll to Security **→ Open Anyway**,
authenticate, then confirm.

This repeats after every update, because each new build is an unnotarized binary
Gatekeeper has never seen. To skip it for good, install without the quarantine
flag instead:

```sh
brew install --cask --no-quarantine maxhafs/tap/vignette
```

and put `export HOMEBREW_CASK_OPTS="--no-quarantine"` in your shell profile so
`brew upgrade` keeps behaving the same way.

## Requirements

- macOS 14+ (built and tested on 26.x, Xcode 26.2, Swift 6.2)
- `brew install xcodegen xcbeautify swiftformat`

## Layout

`Vignette.xcodeproj` is **generated and gitignored**. `project.yml` is the source of
truth — edit that, then `make gen`. Never hand-edit the `.xcodeproj`.

```
project.yml            XcodeGen manifest (targets, build settings, signing)
Sources/App/           Entry point, menu bar UI
Sources/Focus/         Focused-window tracking via the Accessibility API
Sources/Overlay/       Per-screen overlay windows, blur, hole-punch mask
Sources/Permissions/   TCC permission checks and prompts
Resources/             Info.plist, entitlements
Tests/                 swift-testing suite
```

## Commands

| Command | What it does |
| --- | --- |
| `make run` | Build and run in the foreground; logs land in your terminal |
| `make open` | Build and launch detached via LaunchServices |
| `make build` | Build only |
| `make test` | Run the test suite |
| `make fmt` | swiftformat over `Sources` and `Tests` |
| `make kill` | Stop a running instance |
| `make clean` | Drop `build/` and the generated project |
| `make tcc-reset` | Forget the Accessibility grant, to re-test onboarding |

## How it works

One borderless, click-through `OverlayWindow` per screen, each holding a
`ScrimView`: an `NSVisualEffectView` in `.behindWindow` blending mode (which blurs
whatever is rendered beneath it) plus a black tint, masked by an even-odd
`CAShapeLayer` that punches out the focused window.

Two constraints that are load-bearing rather than stylistic:

- **The overlay sits below the menu bar level.** The menu bar is the app's only UI,
  so it has to stay reachable even when the geometry is wrong.
- **`blurView.state = .active`.** The overlay window is never key, and the default
  state switches the blur off whenever that's true — i.e. always.

Focus tracking is `AXObserver`-driven. Drag state is *not*: it comes from polling
`NSEvent.pressedMouseButtons` at 60Hz, because installing an `NSEvent` global
monitor stops `MenuBarExtra`'s status item from opening its menu at all. Moves and
resizes are handled differently on purpose — AX reports live geometry throughout a
resize, but its position attribute is stale for the whole of a drag, so the scrim
stands down for moves and tracks live for resizes.

## To do

Roughly in priority order.

**Punch holes for the focused app's other windows.** Dropdowns, sheets, popovers
and autocomplete panels are separate windows outside the main window's frame, so
they currently get blurred while you're using them. This is the one remaining
issue that reads as a bug rather than a missing feature. Fix: instead of one hole
from `kAXFocusedWindowAttribute`, punch one per window belonging to the focused
app — and include windows with a layer above 0, since menus live there.

**Persist preferences.** The toggle and darken level reset on every launch.
`UserDefaults`, read in `AppModel.init`.

**Narrow drag detection.** Any left-drag suspends the blur, text selection and
file drags included, because `pollMouse` can't tell them apart at the instant
movement starts. Deliberately over-triggers: failing to undim during a real window
drag is a worse outcome than undimming when you didn't need it. If it does become
annoying, the lead is checking at mouse-down whether the press landed on the title
bar — but that risks the worse failure for apps with unusual drag regions.

**Test multi-display.** `FocusedWindow.flipped` anchors to the primary screen's
height, which is exactly where this kind of coordinate maths breaks. One overlay
window per `NSScreen` already exists and screen changes are observed, but none of
it has run against a second monitor. Check that the hole lands on the right
screen, and that hot-plugging a display doesn't leave a stale overlay behind.

**Consider a hotkey.** The menu bar is currently the only way to toggle the blur.

## Releasing

`ci.yml` builds and tests every push and pull request. Releases are cut by tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

`release.yml` then builds Release, signs, zips with `ditto`, publishes a GitHub
Release, and commits an updated cask to the `homebrew-tap` repo. It fails the
build if a release binary ever carries `get-task-allow`.

One-time setup:

1. Create a **public** `homebrew-tap` repo under the same account.
2. Run `scripts/make-signing-cert.sh`, then add the secrets it prints:
   `SIGNING_CERT_P12`, `SIGNING_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`.
3. Create a fine-grained PAT with **contents: write** on the tap repo and add it
   as `TAP_PUSH_TOKEN`.

**Why self-signed rather than ad-hoc.** It does nothing for Gatekeeper — only
notarization does. What it buys is a *stable* signature. Ad-hoc signing produces a
different hash every build, and macOS ties the Accessibility grant to the
signature, so every update would silently kill the app until the user
re-approved it. One persistent certificate keeps the grant across updates.

Release builds use `Resources/Vignette-Release.entitlements`, which omits
`get-task-allow`, and set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` — without that
Xcode injects the entitlement back in regardless of the file.

## Code signing

Signed with a free **Apple Development** certificate (team `AH9NNPN928`), configured in
`project.yml`. Nothing to do — but if you ever set this up on another machine:

1. Xcode → Settings → Accounts → sign in with your Apple ID (free; no paid account).
2. Select the Personal Team → **Manage Certificates…** → **+** → *Apple Development*.
3. Verify with `security find-identity -v -p codesigning`.

**If the identity shows `CSSMERR_TP_NOT_TRUSTED`** it means Apple's WWDR intermediate is
missing, so the cert can't chain to Apple Root CA. macOS may only ship the G1
intermediate, which expired in Feb 2023. Install the current one:

```sh
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
```

The Team ID is the certificate's **OU** field — *not* the ID in parentheses in the
common name, which is a per-certificate identifier. Confirm what actually got used with
`codesign -dvvv <app> 2>&1 | grep TeamIdentifier`.

A paid account ($99/yr) is only needed later, for the **Developer ID** certificate and
notarization that let other people run the app.

## Accessibility permission

`ENABLE_DEBUG_DYLIB: NO` in `project.yml` is **load-bearing**. By default Xcode builds
Debug configs as a stub executable plus a separate `.debug.dylib` (for Preview
hot-reload). TCC can't resolve the app's identity across that split, so the
Accessibility grant silently never applies — the app reports "not trusted" no matter how
many times you tick the box in System Settings. Don't remove that setting.

`make tcc-reset` forgets the grant if you want to re-test onboarding.

## Distribution constraint

Vignette is **not sandboxed** (see `Resources/Vignette.entitlements`). The Accessibility
API against other processes is unavailable to sandboxed apps, which rules out the Mac
App Store. This ships as a notarized Developer ID direct download.
