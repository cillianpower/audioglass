# Audioglass

Audioglass is an actively developed native macOS audio meter app, pairing a translucent glass interface with OpenMeters DSP. It captures system audio, individual applications, or a microphone/interface input and displays six live views: Spectrum, Oscilloscope, Spectrogram, Waveform, Stereometer, and Loudness.

The interface adapts its meter layout to the window shape and includes cursor readouts for inspecting audio. Analysis runs locally; this version does not record or transmit audio.

## Build

Requires macOS 26+, Swift 6.2+, and Rust 1.94+.

```sh
zsh scripts/build-app.sh
open build/Audioglass.app
```

See [FEATURES.md](FEATURES.md) for current parity gaps and [HANDOVER.md](HANDOVER.md) for development notes. OpenMeters-derived DSP is GPL-3.0-or-later; see [LICENSE](LICENSE) and [Rust/UPSTREAM.md](Rust/UPSTREAM.md).
