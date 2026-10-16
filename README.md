<p align="center"><img src="docs/images/icon.png" width="128" height="128" alt=""></p>

<h1 align="center">Audioglass</h1>

<p align="center">Audio meters for macOS, on glass.</p>

![Audioglass in a wide strip, with loudness on the left and the spectrum, oscilloscope, spectrogram, waveform and stereometer reacting to music](docs/images/wide.gif)

Audioglass shows what your Mac is playing across six meters: spectrum, oscilloscope, spectrogram, waveform, stereometer and loudness. You can point it at all of your system audio or at a single app, like your DAW. The DSP comes from [OpenMeters](https://github.com/httpsworldview/openmeters), and the app around it is native AppKit and Metal.

## Install

You'll need macOS 26 or later on an Apple silicon Mac.

1. Grab `Audioglass.zip` from the [latest release](https://github.com/cillianpower/audioglass/releases/latest), unzip it and drag Audioglass into Applications.
2. Open it. It isn't notarized, so macOS will block it the first time. Go to System Settings → Privacy & Security, scroll down and click Open Anyway.
3. Allow system audio recording when it asks. It may ask again after an update.

## Meters

**Spectrum** shows Mid, Side, Left or Right, with an optional second trace behind it. FFT sizes go from 4096 to 32768, and you can choose a linear, log or ERB scale, A-weighting, smoothing and a peak label. Hover to read off the frequency, note and level, or click and hold to freeze it.

**Oscilloscope** locks onto pitch or triggers on zero crossings. It shows one or two channels, overlaid or stacked, with 10 to 100 ms of signal and optional persistence trails.

**Spectrogram** uses time-frequency reassignment by default, which draws much sharper lines than a plain FFT. The plain FFT is still there if you prefer it. FFT size, hop, window, zero padding, scale, floor, tilt, orientation and palette are all adjustable.

**Waveform** scrolls a min/max history of any channel, with an optional second lane and RMS envelope.

**Stereometer** draws a Lissajous or a dot cloud, in a linear or scaled view, with correlation for the full band or split into low, mid and high.

**Loudness** gives you momentary and short-term LUFS, RMS, true peak with optional hold, and a clip warning.

The oscilloscope, waveform and stereometer can scale quiet audio up to fill the view. Readouts and correlation always use the real levels.

## Using it

Pick what to listen to from the Audio Source menu. System Audio covers everything, or you can choose a single running app. Microphones and audio interfaces show up there too, but they haven't really been tested yet.

Settings (⌘,) lets you show, hide and reorder meters and change each meter's options. The same options are in the View menu.

Audioglass lays itself out as a wide strip or a tall column depending on the shape of the window. ⌘2 and ⌘3 lock it to one or the other, and ⌘1 goes back to automatic. In a strip the loudness readings sit on the left, and in a column they move to the top.

A few other things worth knowing:

- Hold Shift and drag between two meters to resize them. View → Reset Section Sizes puts them back.
- Hover over any graph to see exact values.
- Click the loudness readings to clear held peaks and the clip warning, or drag them to move the window.
- ⌘R restarts capture and clears the history.
- View → Frame Rate switches between 60 and 120 fps.

Your window, layout, meter sizes and settings are saved between launches.

## Building

You'll need macOS 26, Xcode 26 and Rust 1.94 or newer.

```sh
zsh scripts/build-app.sh
open build/Audioglass.app
```

To run the tests:

```sh
cargo test --manifest-path Rust/Cargo.toml
zsh scripts/test-transport.sh
```

There's an overview of how it all fits together in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What's next

More controls for each meter, frequency labels and zoom for the spectrogram, and maybe separate windows for each meter. I'm not planning to add VU meters, recording, plug-ins or presets.

## License

Audioglass is licensed under [GPL-3.0-or-later](LICENSE). The analysis code in `Rust/src/` is adapted from [OpenMeters](https://github.com/httpsworldview/openmeters) 1.15.2 by Maika Namuo, which uses the same license. [Rust/UPSTREAM.md](Rust/UPSTREAM.md) lists exactly what changed from upstream.
