# bd-hdr-unclamp

Keep a tuned SDR desktop look **and** full-range HDR on the same display, by stepping the
look out of the way only while fullscreen content is on screen.

If you run a BetterDisplay-style colour look (brightness above 1.0, a gamma curve, a
temperature shift) on an HDR display under macOS, the look and HDR fight each other: the
transfer-table adjustments clamp everything above SDR white, so HDR content comes out at
ordinary-white brightness. This tool neutralises exactly those settings while a fullscreen
window is up, then puts your own values back.

## Measured, not assumed

All numbers below are from an i1d3 through ArgyllCMS with a QD-OLED correction, on an
Alienware AW3425DW (QD-OLED, 3440x1440) over Thunderbolt, macOS 27.2, 10-bit HDR10 link.

A 1000-nit PQ patch, 10% window:

| BetterDisplay state | measured |
|---|---|
| brightness 1.15, gamma −0.34, temperature −0.03 (tuned look) | **379 nits** — clamped at SDR white |
| brightness 1.0, gamma 0, temperature 0 (neutralised) | **459–466 nits** (True Black OSD) / **~1030 nits** (Peak 1000 Bright) |

Which settings cause the clamp, isolated one at a time:

| change | HDR ceiling |
|---|---|
| brightness > 1.0 | clamped to the boosted SDR white (316–415 nits) |
| gamma ≠ 0 | clamped (~288 nits) |
| temperature ≠ 0 | clamped (~276 nits) |
| **saturation** (any value) | **no effect — free** |

So the fix is narrow: neutralise brightness/gamma/temperature, leave saturation alone.

## What it does

- Detects a window that covers the target display, owned by a regular (foreground) app.
- Saves your current brightness/gamma/temperature, applies neutral values, and logs it.
- Restores **the values it saved** — not hard-coded ones — when the window goes away.
- Persists state to disk and reconciles on startup, so a crash or a logout can never leave
  your display neutralised.
- Re-asserts the active state periodically, so a BetterDisplay restart or a stray slider
  nudge doesn't silently put the clamp back.

Measured switch latency with the shipped timings: **entry 1.1–1.7 s, exit 1.0–1.4 s**.

## Install

```sh
./install.sh
```

Builds the binary into `~/bin`, writes `~/Library/LaunchAgents/com.adam.bd-hdr-unclamp.plist`
and loads it. Requires the Xcode command line tools (`swiftc`) to build.

## Usage

```sh
bd-hdr-unclamp --status    # current mode, pause flag, saved values
bd-hdr-unclamp --pause     # kill switch: stop touching the display
bd-hdr-unclamp --resume
bd-hdr-unclamp --once      # single evaluation (also: --dry-run to log without acting)
```

## Configuration

Edit the constants at the top of `bd-hdr-unclamp.swift`:

- `targetScreenName` — must match `NSScreen.localizedName` for the display.
- `pollSeconds`, `graceSeconds`, `graceExitSeconds` — switch latency vs flicker tolerance.

## Limits, honestly

- **The signal is geometry, not "HDR content".** macOS exposes no API for "an EDR surface is
  being presented". Any window covering the display counts, so a maximised non-video window
  will also trigger it (harmless: you lose the look briefly). Windowed HDR video and
  picture-in-picture will *not* trigger it.
- **The OSD mode is not touched.** It can't be: the monitor ignores DDC writes for these
  controls in HDR, and the HDR preset isn't exposed over DDC at all. If you want 1000-nit
  peaks rather than ~465, select that mode on the monitor itself.
- **Pausing the video keeps HDR active** — the window is still fullscreen. Leaving fullscreen
  is what restores the look.
- Tested on one machine, one display, one macOS build. Sleep/wake, dock reconnects and
  multi-display setups are handled by design (display resolved by name each poll, state
  reconciled on startup) but are not exhaustively tested.

## Why this exists

macOS applies any third-party gamma-table adjustment to a [0,1] domain, so values above 1.0 —
which is what HDR is — clamp at the top of the table. There is no supported way around it, and
the ICC profile path does not help: we measured that the profile's tone curve is ignored in
HDR mode, its matrix is honoured for permutation but normalised for scaling, and the declared
white point is ignored. The only workable arrangement is to not have those adjustments applied
while HDR content is on screen.

## Licence

MIT.
