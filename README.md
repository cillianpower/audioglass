# Audioglass

Audioglass is an actively developed native macOS audio meter app, pairing a translucent glass interface with OpenMeters DSP. It captures system audio, individual applications, or a microphone/interface input and displays six live views: Spectrum, Oscilloscope, Spectrogram, Waveform, Stereometer, and Loudness.

The interface adapts its meter layout to the window shape and includes cursor readouts for inspecting audio. Analysis runs locally; this version does not record or transmit audio.

## Controls

- Hold **Shift** and drag the divider between meters to resize adjacent sections. Horizontal and vertical sizes are saved separately; small windows scroll to keep meters readable.
- Open **Audioglass → Settings…** or press **⌘,** to toggle modules, reorder the interactive meters, and configure FFT smoothing and analysis. At least one stays visible. **Reset Section Sizes** restores equal sizing.
- Choose **60 or 120 fps** in **Settings → Frame Rate**. The display-synchronized rate is saved, defaults to 120 fps, and is limited by your display’s refresh rate.
- In Settings, independently toggle **Oscilloscope / Waveform / Stereometer Normalization** (on by default). Quiet audio expands to fit the view; level readouts and correlation use the original audio.
- Click and hold the **Spectrum** to freeze its trace and cursor readings; release to resume. Other meters continue updating.
- In horizontal mode, graph names and normalization/hold status appear in the hover readout, leaving more height for the plots. Vertical mode keeps its headings.
- Loudness and audio information stay in the left column; interactive meters use the full height to its right. Drag the slim **top bar** to move the window.

## Build

Requires macOS 26+, Swift 6.2+, and Rust 1.94+.

```sh
zsh scripts/build-app.sh
open build/Audioglass.app
```

See [FEATURES.md](FEATURES.md) for current parity gaps and [HANDOVER.md](HANDOVER.md) for development notes. OpenMeters-derived DSP is GPL-3.0-or-later; see [LICENSE](LICENSE) and [Rust/UPSTREAM.md](Rust/UPSTREAM.md).
