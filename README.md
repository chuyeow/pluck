# Pluck

Menu bar app that copies text from anything on your screen. Press **⇧⌘2**, drag over a region on any display, and the recognized text is on your clipboard. A TextSniper clone built on Vision.

## Features

- Capture text from any region (images, videos, PDFs, apps that block selection). Space toggles window mode; Esc cancels.
- QR codes and barcodes: the payload is copied instead of OCR output.
- Configurable global shortcut: menu › Change Shortcut…
- Keep Line Breaks: off joins lines into one paragraph and repairs hyphenated words.
- Append to Clipboard: adds each capture to what is already copied.
- Speak Captured Text: reads the result aloud.
- Sound: pick the capture sound: Koto (default), Kalimba, Droplet, Woodblock, Chime, Seed, or None. Choosing one plays it. The sounds are synthesized by `scripts/make_sounds.py` (stdlib Python); edit and rerun it to tune them.
- Launch at Login.
- CLI: `/Applications/Pluck.app/Contents/MacOS/Pluck image.png` prints recognized text.

## Build

```sh
swift test                  # core tests (OCR, QR, formatting, shortcut)
scripts/bundle.sh --install # builds build/Pluck.app and copies it to /Applications
open /Applications/Pluck.app
```

## CI and releases

- `.github/workflows/test.yml` runs `swift test` and builds the bundle on every push and pull request.
- `.github/workflows/release.yml` runs on every push to `main`: tests, builds `Pluck-1.0.<run>.dmg` with `scripts/dmg.sh`, and publishes it as a GitHub release tagged `v1.0.<run>`.

CI builds are ad-hoc signed and not notarized. On another Mac, Gatekeeper blocks the first launch: right-click Pluck.app › Open, or run `xattr -dr com.apple.quarantine /Applications/Pluck.app`.

On first launch, grant Screen Recording in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch Pluck. Without it, captures contain only the wallpaper.

The bundle is signed with your first Apple Development identity so the Screen Recording grant survives rebuilds. Override with `SIGN_IDENTITY=...`; with no identity it falls back to ad-hoc signing, which resets the grant on every build.

To check the shortcut window's look without a Screen Recording grant, render it offscreen:
`.build/debug/Pluck --snapshot-shortcut-window out.png [light|dark] [recording]`.

The first launch after install compiles Vision's models in the background (about 1–2 minutes). Later captures take under a second.
