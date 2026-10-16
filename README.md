# Audioglass

Native macOS audio meters on a translucent glass window. Audioglass listens to everything your Mac plays, or to a single app such as your DAW, and draws six live views with DSP from [OpenMeters](https://github.com/httpsworldview/openmeters): Spectrum, Oscilloscope, Spectrogram, Waveform, Stereometer, and Loudness.

<!-- screenshot -->

Analysis runs entirely on your Mac. Audioglass does not record, store, or transmit audio.

## Meters

- **Spectrum**: FFT up to 32768 points, Mid/Side/Left/Right source with an optional second trace, linear/log/ERB frequency scale, A-weighting, smoothing, peak label. Hover for Hz, note, cents, and dB; click and hold to freeze.
- **Oscilloscope**: pitch-stable or zero-crossing trigger, one or two channels overlaid or stacked, 10–100 ms capture, persistence trails.
- **Spectrogram**: sharpened time-frequency reassignment or classic FFT; FFT size, hop, window, zero padding, frequency scale, floor, spectral tilt, scroll or waterfall orientation, and glass or heat palette. Rendered with Metal.
- **Waveform**: scrolling min/max history of any channel, with a second lane and an RMS envelope available.
- **Stereometer**: Lissajous or dot cloud, linear or scaled radial view, three rotations, and full-band or low/mid/high correlation.
- **Loudness**: momentary and short-term LUFS, RMS, true peak with hold, and a clip indicator.

Oscilloscope, Waveform, and Stereometer can scale quiet audio to fill the view. Readouts and correlation always use the actual levels.

## Install

Requires macOS 26 or later on Apple silicon.

1. Download `Audioglass.zip` from the [latest release](https://github.com/cillianpower/audioglass/releases/latest), unzip it, and move **Audioglass** to Applications.
2. Open it. Audioglass is not notarized, so macOS will block the first launch. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
3. Allow **system audio recording** when asked. macOS may ask again after you update Audioglass.

## Use

- **Audio Source** menu: choose System Audio or a single running app. Audio interface and microphone inputs are also listed, but have had less testing.
- **Settings (⌘,)**: show, hide, and reorder meters, plus every per-meter option. The same options are under **View** in a submenu for each meter.
- **Layout**: Automatic (⌘1) picks a horizontal strip or a vertical column from the window's shape; Horizontal (⌘2) and Vertical (⌘3) fix it. **Window → Meter Strip / Meter Column** resize to presets.
- **Resize meters**: hold Shift and drag the divider between two meters. **View → Reset Section Sizes** evens them out.
- **Hover** any graph for readouts. In horizontal layout, meter names appear in the hover card to leave more room for the plots.
- **Loudness**: click the readout to clear held peaks and the CLIP badge.
- **Move the window** by dragging the slim bar at the top of the left column.
- **View → Reset Analysis (⌘R)** restarts capture and clears history. **View → Frame Rate** chooses 60 or 120 fps (120 by default, limited by your display).

## Build from source

Requires macOS 26+, Xcode 26 (Swift 6.2+), and Rust 1.94+.

```sh
zsh scripts/build-app.sh
open build/Audioglass.app
```

Tests:

```sh
cargo test --manifest-path Rust/Cargo.toml
zsh scripts/test-transport.sh
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

## Roadmap

Planned work: more per-meter controls, spectrogram frequency labels and zoom, and possibly separate meter windows. VU meters, recording, plug-ins, and presets are out of scope.

## License and credits

Audioglass is free software under the [GNU General Public License v3.0 or later](LICENSE).

The audio analysis in `Rust/src/` is adapted from [OpenMeters](https://github.com/httpsworldview/openmeters) 1.15.2 by Maika Namuo, also GPL-3.0-or-later. [Rust/UPSTREAM.md](Rust/UPSTREAM.md) records the pinned upstream commit and every change made to it.
