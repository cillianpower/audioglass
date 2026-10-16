# Architecture

Audioglass has three layers: a Rust DSP library, a small C bridge for real-time audio transport, and an AppKit app that captures audio and draws the meters.

```
Core Audio tap / input device
  │  HAL I/O callback (real-time thread)
  ▼
Sources/DSPBridge/bridge.c     lock-free single-producer/single-consumer stereo ring
  │  analysis queue drains the ring
  ▼
Rust/ (libaudioglass_dsp.a)    OpenMeters processors + Audioglass ingestion/snapshots
  │  C ABI declared in Sources/DSPBridge/include/DSPBridge.h
  ▼
Sources/Audioglass/            AppKit plots, Metal spectrogram, menus and settings
```

## Capture

`AudioCapture.swift` creates a Core Audio process tap (all system audio, or one app's processes) wrapped in a private aggregate device, or opens an input device directly. The HAL I/O callback calls `ag_transport_push`, which converts mono, interleaved, or planar float32 into a bounded stereo ring and counts dropped frames instead of blocking. Every second the app checks for default-output and format changes and restarts capture when they occur.

## Analysis

`AnalysisEngine.swift` drains the ring on a serial queue and feeds `ag_ingest`. The Rust `Engine` in `Rust/src/lib.rs` owns one instance of each upstream processor and turns their output into flat float buffers for Swift: spectrum and scope traces (`ag_process`), waveform history, stereo points, and loudness metrics (`ag_read_meters`), and timing for cursor readouts (`ag_read_timing`). Meter options are set with `ag_configure` and `ag_configure_options`. Expensive optional analysis, such as waveform RMS bands and stereo band correlation, runs only while a visible setting needs it.

Each display tick takes the most recent snapshot. Only one analysis job can be in flight at a time, so a slow frame drops work instead of queueing it.

## Layout

`MeterContainer.swift` decides between a wide strip and a tall column. It uses the window's shape when the layout is Automatic. In a strip, the source and loudness readings sit in a fixed left sidebar, and the meters fill the remaining width and never scroll vertically. In a column, the readings form a block across the top beside the traffic lights, and the stacked meters scroll only when the window is too short for them. Shift-drag sizes are stored per orientation.

## Rendering

Plots are drawn in AppKit as thin white line segments over `NSGlassEffectView`. `PixelTrace.swift` reduces dense traces to min/max per physical pixel column so path size stays bounded at 120 fps. `NSWindow.displayLink` drives redraws at the selected frame rate. While the window is hidden, a 30 Hz timer keeps capture and history current.

The spectrogram is the exception. `Rust/src/spectrogram_raster.rs` rasterizes processor columns at physical-pixel frequency resolution. Reassigned points accumulate power at their time-offset column, and classic FFT columns interpolate bins. Only changed columns cross the FFI (`ag_spectrogram_pending` / `ag_spectrogram_read`). `SpectrogramView.swift` keeps them in a private Metal ring texture updated by blit inside each frame's command buffer. Floor, tilt, and palette are shader uniforms, so changing them recolours history instantly. Raw columns are kept within a 64 MB budget so that resizes and scale changes can re-render history.

### Why not upstream's renderer

OpenMeters renders with Iced and wgpu, pinned to Vulkan. Porting it would bring a second windowing and UI stack into a native AppKit window. Audioglass consumes the processors' snapshots instead, and uses a small native Metal pipeline only where per-pixel work needs it.

## Upstream code

`Rust/src/dsp.rs`, `macros.rs`, `util*`, and the six `visuals/*/processor.rs` files come from OpenMeters at a pinned commit. They are kept as close to upstream as possible so updates can be diffed. [Rust/UPSTREAM.md](../Rust/UPSTREAM.md) lists every deliberate difference.

## Settings

Every option is a `UserDefaults` key that the View menu and the Settings window share. Both call the same actions, so they stay in sync. Interactive meter order and horizontal/vertical section sizes are stored separately. The bundle identifier is part of where these settings and the system audio permission live, so changing it resets both.

## Tests

- `cargo test --manifest-path Rust/Cargo.toml`: upstream processor tests (loudness checked against the `ebur128` reference), plus bridge and raster tests for real PCM, option changes, timing, and spectrogram placement.
- `zsh scripts/test-transport.sh`: the C ring buffer under AddressSanitizer and UBSan, covering mono, planar, NaN, overflow, and concurrent wraparound.
