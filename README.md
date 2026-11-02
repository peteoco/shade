# Blackout

Turn any display off without unplugging it. One click, one hotkey, and you can never lock yourself out.

Blackout is a free, open-source macOS menu bar app that switches individual displays off and back on. It is handy for turning off a MacBook's built-in screen while it's docked with the lid open, or for blanking a monitor you aren't using.

## Features

- **Per-display toggle.** Turn any connected display off or on from the menu bar.
- **Off displays stay listed**, so you can turn them back on with one click.
- **Turn All On** brings every display back at once.
- **Global hotkey:** `Ctrl` + `Option` + `Cmd` + `B` turns all non-main displays off or on.
- **Launch at login** (uses `SMAppService`).
- **Back on at wake.** All displays are turned on again when your Mac wakes from sleep.
- **Can't lock you out.** Blackout won't turn off your last active display.

## Install

1. Download the latest `Blackout.zip` from [Releases](../../releases).
2. Unzip it and move `Blackout.app` to `/Applications`.
3. Open it. A Blackout icon appears in the menu bar.

### Opening an unsigned app

Blackout isn't notarized yet, so Gatekeeper blocks it the first time you open it. You can get past this in any of these ways:

- **Right-click (or Control-click) `Blackout.app` in Finder, choose Open, then click Open in the dialog.**
- Or try to open it once, then go to **System Settings > Privacy & Security**, scroll down, and click **Open Anyway**.
- Or remove the quarantine flag in Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Blackout.app
  ```

You only have to do this once.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/peteoco/blackout.git
cd blackout
./build.sh
```

`build.sh` compiles `main.swift` and packages `Blackout.app` with `AppIcon.icns`.

## Safety

Blackout is built so you never get stuck with a black screen:

- It won't turn off the last display that's still on.
- Every display comes back on when your Mac wakes.
- **Turn All On** and the hotkey restore your displays at any time.

If something goes wrong, unplugging and reconnecting a display, or restarting your Mac, also turns it back on.

## Private API caveat

To turn displays off, Blackout calls `CGSConfigureDisplayEnabled`, a private macOS API that Apple doesn't document. Other display utilities use the same call. Because the API is private:

- A macOS update could change it or break it.
- Blackout can't be sold in the Mac App Store.
- Results can differ between Apple silicon and Intel Macs, and between display setups.

If something breaks after an update, please [open an issue](../../issues) and include your Mac model and macOS version.

## License

[MIT](LICENSE) © 2026 Peter O'Connell
