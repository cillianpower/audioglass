# OpenMeters DSP extraction

Source: https://github.com/httpsworldview/openmeters
Commit: c488209234c617199d362e952d350f96a6a769d7 (1.15.2)
Copyright (C) 2026 Maika Namuo; GPL-3.0-or-later.
The full GPL text is at ../LICENSE.

Copied `dsp.rs`, `macros.rs`, `util.rs`, `util/audio.rs`, `util/audio/*`, and all six visuals' `processor.rs` files: spectrum, oscilloscope, spectrogram, waveform, stereometer, and loudness. All six processor files were checked byte-for-byte against this pinned commit on 2026-10-07 before cursor work. The oscilloscope snapshot now adds capture-duration and cycle-frequency metadata, and exposes the existing cycle-rate accessor for native cursor readouts. Trigger and measurement algorithms are unchanged; the other five processor files remain unchanged. `util.rs` omits the UI-only color module. Module roots expose the six processors. `lib.rs` is Audioglass's PCM ingestion/configuration/snapshot bridge; generated tones exist only in test fixtures.

The original Iced/wgpu renderer is not included. Native AppKit consumes processor snapshots and draws white straight segments. A native Metal texture renders the classic spectrogram; the bridge rasterizes its packed dB columns to a bounded logarithmic frequency grid. Reassignment is not enabled in the app yet. Waveform and spectrogram histories are bounded by the bridge. True peak display decay is added by the bridge; upstream measurement is unchanged. Spectrum configuration maps directly to upstream settings, including raw, exponential, and peak-hold averaging.

Loudness tests use the upstream ebur128 reference dependency. Cargo.lock pins resolved dependencies. See ../FEATURES.md for remaining parity work.
