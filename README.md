# Vignette

macOS focus aid: blurs everything except the focused window.

Working name — rename freely (it appears in `project.yml`, `Resources/`, and `Makefile`).

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
Sources/Overlay/       Overlay windows + blur (not built yet)
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

## Code signing — read this before you lose an afternoon

macOS ties the Accessibility grant to the app's **code signature**. The project
currently signs ad-hoc (`CODE_SIGN_IDENTITY: "-"`), which produces a different hash on
every build — so every rebuild silently revokes Accessibility, and the app goes dead
with no error. You'd be re-toggling the System Settings checkbox all day.

The fix is free and takes two minutes:

1. Xcode → Settings → Accounts → **+** → sign in with your Apple ID. This creates a
   free "Personal Team" and an `Apple Development` certificate.
2. `security find-identity -v -p codesigning` — copy the identity name and team ID.
3. In `project.yml`, set `CODE_SIGN_IDENTITY: "Apple Development"`,
   `CODE_SIGN_STYLE: Automatic`, and `DEVELOPMENT_TEAM: <YOUR_TEAM_ID>`.
4. `make clean && make run`, grant Accessibility once — it now survives rebuilds.

A paid account ($99/yr) is only needed later, for the **Developer ID** certificate and
notarization that let other people run the app.

## Distribution constraint

Vignette is **not sandboxed** (see `Resources/Vignette.entitlements`). The Accessibility
API against other processes is unavailable to sandboxed apps, which rules out the Mac
App Store. This ships as a notarized Developer ID direct download.
