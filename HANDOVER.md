# Audioglass handover

Updated 2026-10-07. Continued the 2026-10-02 handover: live capture, all six upstream meters, native controls/persistence, bounded transport, and a native Metal spectrogram now exist. Full OpenMeters/MiniMeters feature parity is **not complete**; [FEATURES.md](FEATURES.md) is the detailed gap list.

## 2026-10-08 rendering and normalization update

- Visible rendering/analysis uses `NSWindow.displayLink` with a preferred rate of 60 or 120 fps, selected through Settings → Frame Rate and persisted via `FrameRate` (default 120). Changes apply immediately. The actual cadence depends on display refresh, system scheduling, and rendering cost; sustained 120 fps throughput has not been measured. A 30 Hz background timer only runs while occluded/hidden/minimized to keep capture/history current. Worker snapshots are presented on display ticks; only one analysis job may be in flight.
- Independent Oscilloscope, Waveform, and Stereometer Normalization controls appear in native Settings and the View menu. Enabled by default, persisted via `NormalizeScope`, `NormalizeWaveform`, `NormalizeStereo`. Scaling affects drawings only, not raw hover amplitudes, level meters or correlation. Waveform shares gain across the entire visible stereo history; stereometer uses shared radial gain to preserve stereo balance.
- `DisplayNormalization.swift`: 95% peak fit, immediate gain reduction for louder peaks, 250 ms release for gain increases, silence reset and amplification floor at −80 dBFS. Scope hover marker uses the same display gain as its trace.
- `PixelTrace.swift`: FFT and scope drawing retains ordered min/max extrema per physical pixel column to bound path segments at high frame rates. Full analysis snapshots remain available for hover readouts.
- Build passed. Live quiet audio visually filled normalized scope/waveform/stereo views; their NORM labels were visible. No sustained FPS benchmark or calibrated normalization test has been run.

## 2026-10-08 interface update

- Native **Audioglass → Settings… (⌘,)** opens a separate settings window. The front-facing Settings button and full-width info header are removed.
- Loudness is pinned in the left column with source, sample rate, and capture status; it can still be hidden. Interactive meters occupy the full height to its right. The slim top area handles window dragging; meter bodies do not move the window.
- Settings exposes module visibility, persisted Move Up/Down ordering for the five interactive meters, layout, FFT smoothing and existing analysis controls. Loudness stays pinned independently of ordering. `MeterOrder` persists all interactive modules, including hidden ones.
- Shift-drag dividers resizes adjacent interactive meters; separate horizontal/vertical size weights persist. Click-and-hold spectrum freezes trace and readouts while other analysis continues; release/deactivation clears the hold.
- `MeterSettingsWindow.swift` implements the native controls, dispatching to the same menu actions to keep settings synchronized.
- Build succeeded. Native UI confirmed ⌘, opens Settings, reordering both directions, smoothing selection and restoration, and the compact main layout. Original module order and smoothing Off restored. Full sustained-hold/Shift-drag coverage remains unverified.
- A native CoreText exception occurred in the existing meter label drawing during the first reorder check. Meter/sidebar labels now use Menlo rather than the variable system monospace font. Repeated ordering/smoothing checks then completed without a crash; this is limited validation, not a long-duration stability result.

## Repository

Private repository: https://github.com/cillianpower/audioglass-private (`private` remote). The earlier private `cillianpower/audioglass` repository remains configured as `origin`. The current branch tracks `private/main`. Build artifacts remain ignored.

## Product direction and authorization

The user approved the existing glass direction. Preserve ordinary macOS window behavior, full-size glass beneath native traffic lights, hidden title/no separate titlebar, normal window level, white thin straight trace segments, spectrum smoothing Off by default, and horizontal/vertical/automatic layouts. This should become a native glass alternative with OpenMeters/MiniMeters feature completeness.

The user previously authorized unattended Ableton/Audioglass computer-use tests and explicitly asked not to repeat capability probing. Proceed with actual implementation. No distribution/deployment has been requested.

## Current implementation

- `Sources/Audioglass/App.swift`: AppKit app, native menus, glass window, six meter drawing, persisted controls, 30 Hz analysis scheduling, source changes/shutdown joined with the analysis queue. Native window minimum remains 280×150, normal level, desktop tiling eligibility, saved `AudioglassWindowStudy` frame. Dock reopen explicitly restores a minimized window.
- `Sources/Audioglass/AudioCapture.swift`: Core Audio system/per-app process taps. Taps are private, stereo mixdown, explicitly **unmuted**; private tap-only aggregate device. App sources use macOS 26 bundle IDs and process restoration. Float32 microphone/interface inputs have a separate native device path and request microphone consent on first explicit selection. Physical inputs currently use the first two channels (mono duplicates). Input/device/source enumeration persists stable UIDs; own aggregate is excluded.
- `Sources/DSPBridge/bridge.c`: preallocated 65,536-frame stereo SPSC ring using C atomics, float32 interleaved/planar/mono conversion, nonfinite sample sanitization, overflow counters, native C HAL callback. No allocations, locks, dispatch, Swift/Obj-C, or DSP in callback. Whole incoming blocks drop on overflow; worker clears DSP history and buffered pre-gap data.
- `Sources/Audioglass/AnalysisEngine.swift`: serialized Rust handle; ingestion drains up to 16 blocks of 4,096 frames per job; immutable snapshots passed to main. Settings apply before ingestion. Analysis continues while hidden/minimized to keep history and transport current; drawing pauses.
- `Sources/Audioglass/MeterContainer.swift`: transparent native scroll container. Strip/column presets fit six readable meters; smaller windows scroll. Automatic layout chooses a single horizontal row or vertical column from viewport aspect ratio, with 0.9/1.1 hysteresis around square. Strip/column presets keep Automatic selected. `StripLayoutMode` replaces the old `MeterArrangement` preference so existing installs default to automatic on this update. Scroll content avoids automatic titlebar insets and opaque clip background.
- `Sources/Audioglass/SpectrogramView.swift`: native Metal R8 texture with premultiplied white-alpha fragment output. Each snapshot receives a fresh small texture so GPU reads cannot race CPU uploads. Rendering is manual/paused when not needed; AppKit draws the other plots/grids/labels.
- `Rust/src/lib.rs`: PCM ingestion, configuration, bounded histories, six snapshot bridge. Production sample generator is **removed**; tone fixtures exist only in tests. Waveform history is bounded to 1,024 columns; classic spectrogram to 512×192 raster. True-peak display decay is 20 dB/s; underlying measurement is upstream.
- All six `Rust/src/visuals/*/processor.rs` files are copied from pinned OpenMeters 1.15.2 commit `c488209234c617199d362e952d350f96a6a769d7`. They were checked byte-for-byte against that commit before hover work. Oscilloscope now adds capture-duration/cycle-frequency snapshot metadata and exposes the existing cycle-rate accessor; trigger algorithms are unchanged. The other five processors remain unchanged. GPL-3.0-or-later, copyright Maika Namuo. Attribution/license are included in app resources and native About panel.

Native controls:

- Audio Source: Stopped, System Audio, running apps, microphone/interface inputs.
- Meters: independently show/hide all six; at least one remains visible.
- Automatic/Horizontal/Vertical layouts; Window → Meter Strip / Meter Column.
- Spectrum: FFT 4096/8192/16384/32768, Mid/Side/Left/Right (shared with scope), range −60/−90/−120 dB, unweighted/A-weighted, smoothing Off/Light/Medium/High/Peak Hold (12 dB/s).
- Scope: zero crossing (50 ms), stable 1/2/4 cycles, no added smoothing.
- Waveform: 2.56/5.12/10.24-second stereo min/max history.
- Stereo: rotated raw L/R trace and full-band correlation.
- Loudness: momentary/short-term LUFS, fast RMS L/R, true peak L/R.
- Reset Analysis (⌘R): restart selected source and clear history.

Source, visibility, layout, analysis settings, and frame persist. CAPTURING means HAL callbacks are advancing (possibly silence), **not proof of consent or audible signal**. WAITING FOR STREAM means callbacks have not advanced since the last control poll. Tap/default output/format changes are polled each second and restart capture. Error messages point to system audio permissions; microphone consent failures need appropriate input messaging improvements.

Bundle: `build/Audioglass.app`, ID `com.cillianpower.audioglass.study` retained for window/preferences/permission continuity, version 0.2.0. Locally/ad-hoc signed, macOS 26+. Source is tracked in Git. `.gitignore` now excludes build outputs and Rust target files.

## Validation

```sh
zsh scripts/build-app.sh
cargo test --manifest-path Rust/Cargo.toml --quiet
zsh scripts/test-transport.sh
codesign --verify --deep --strict build/Audioglass.app
```

Completed:

- Rust/Swift build succeeded, including input path and native Metal pipeline.
- **72 Rust tests passed** (66 included upstream tests + 6 bridge tests), including ebur128 reference comparisons, real PCM FFT/scope, supplementary meter buffers/guard sentinels, sample-rate reconfiguration, mono/Side selection, FFT/config changes.
- C transport tests passed under AddressSanitizer/UBSan: mono duplication, planar conversion, NaN handling, bounded overflow, concurrent producer/consumer ordering and wraparound.
- Five processor files byte-identical to pinned upstream; scope has metadata-only additions documented in `Rust/UPSTREAM.md`.
- App signature verification succeeded.
- Native UI confirmed system and Live-only capture of Ableton metronome, responding FFT, waveform clicks, spectrogram history, loudness and +1 mono correlation. Playback test used transport/metronome only, then stopped playback and disabled metronome; no musical edits or set save. Arrangement position advanced during testing.
- Final alpha-corrected Metal spectrogram and six views also responded to an 8-second soft 440 Hz stereo WAV played by `afplay` through actual system output. Fixture is `build/tests/capture-tone.wav`. Playback completed. System output also contains ambient audio; this is visual confirmation, not a calibrated amplitude comparison.
- Final strip (1200×240) and column (350×900) screenshots verified all six readable views. Titlebar remains hidden; glass beneath traffic lights. Column header was subsequently made compact to avoid clipping.
- Relaunch restores selected source and saved frame. FFT was exercised at 32768 in native menu, then restored to 16384. Smoothing remained Off.
- Input menu enumerated Push 3, Scarlett 4i4, and available microphones. **Actual input capture/consent was not tested.** Own tap aggregate appeared initially and is now filtered out.

Not completed / do not claim passed:

- Fresh system-capture consent or denial/revocation scenarios.
- Real microphone/interface capture and input permission cases; device channel-pair selection.
- Physical output/input device disconnection, output routing changes, sample-rate changes under live capture. Processor sample-rate behavior is tested, control-layer hardware switching is not.
- Full Ableton native tiling pair/swap/quarter matrix, edge/corner resize matrix, minimize/restore and idle/wake coverage. Native tiling menu actions were attempted and window geometry changed, but pairing/swap results were not established. Minimize was attempted; the tool can still return a cached/gray window screenshot, so that does not establish a successful minimize/restore test.
- Minimum-size scroll interaction, history timing under sustained load, GPU performance benchmarks.

Final state: rebuilt app is running with Automatic layout enabled, currently in the six-meter horizontal strip. Both strip and column presets were visually verified with Automatic active; resizing between wide and tall windows changes orientation. System Audio selected, smoothing Off, FFT 16384. Private capture aggregate exclusion was verified in the native input menu.

## Next work

1. **Capture validation and lifecycle hardening**: input permission UI, real Scarlett/Push capture, routing/channel pair, disconnection and format-switch tests, consent/denial/revocation, distinguish silence from inaccessible capture where public APIs permit. Ensure unknown/no-device errors are recoverable and no stale frame is presented after capture stalls.
2. **Finish upstream meter/display controls**: dual spectrum/scope traces, window and axis choices; scope independent trigger/time/gain; waveform band/history overlays; stereo scale/Lissajous/band views and correlation; loudness mode selection/hold/clip indicators.
3. **Spectrogram completeness**: implement reassigned rasterization with upstream time offsets and power accumulation/normalization (not just plotting each point in its current column), expose FFT/hop/window/duration/orientation/range controls. Current classic renderer is usable but its 192-row log raster needs fidelity/performance refinement.
4. **Native UX/window tests**: run Ableton pairing matrix, resize/minimize/restoration tests; add meter reordering/resizing/popout windows and presets. Keep approved glass/white/raw styling.
5. **MiniMeters remaining products/features**: current MiniMeters lists a seventh VU module, local recording/clipping (10/60 s), target-curve import, and sender/individual AU/VST3/CLAP plug-ins. These are on `FEATURES.md`; six working meters are not full current MiniMeters parity.
6. Release packaging/icon/signing/notarization only when requested. No distribution authorized.

## Computer use and references

Use `mcp__cua_repl` for native UI. Bundle-ID binding is more reliable than app-path binding. After rebuilding, quit/relaunch the actual executable. `getApp` by bundle ID can relaunch it; do not assume unavailable `cua.computer.launch_app` exists. Fresh AX state is required after every action. Native menu Cancel secondary action helped dismiss a stuck menu; native window Raise helped reliably focus before Quit. Resetting cua bindings recovered prior stale state/stream errors. Avoid interpreting actions or screenshots of cached/minimized windows as verified effects.

Ableton: `/Applications/Ableton Live 12 Suite.app`, bundle ID `com.ableton.live`, existing Untitled set. No set save performed.

Pinned upstream checkout restored at `/tmp/audioglass-openmeters`; Apple sample at `/tmp/audioglass-apple-taps` (temporary).

Local Scrap reference: `/Users/cillian/Development/tools/Scrap/Scrap/Scrap/ContentView.swift` (`WindowConfigurator`, `GlassNSView`). Public macOS 26 glass APIs only.

See `README.md`, `FEATURES.md`, `Rust/UPSTREAM.md`, and the historical `EXPLORATION.md`. The latter contains older architecture experiments; current implementation is described here.

## Cursor work (2026-10-07)

User clarified that Waveform history and Oscilloscope cycle behavior are correct; do not change their semantics. All four requested plots now have hover cursor guides and live readouts: Spectrum Hz/note/cents/dB/channel, Scope actual capture time/amplitude/dBFS/pitch-lock state, Spectrogram raster Hz/note/column age/approximate row-peak level, Waveform age/channel/min/max/peak. AppKit overlay sits above Metal and ignores hit testing; Metal also delegates hit testing to MeterView. Readouts work with pointer movement and refresh with analysis snapshots. Spectrogram values reflect its clipped/quantized −100 to 0 dB raster and explicitly mark approximation and empty history.

`ag_read_timing` exports sample rate, actual scope span, locked cycle Hz, spectrogram hop duration and populated column count. New bridge regression verifies one-cycle timing at 110 Hz, pitch release on silence, column timing/count and output sentinel. All 72 tests passed. App rebuilt/relaunched, and all four readouts visually verified in a tall column using native UI cursor placement; Spectrogram overlay appeared above Metal. No waveform/scope display-mode or default changes. App is running with System Audio and Automatic layout. Full hover/resize/scroll matrix remains untested.
