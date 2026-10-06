# Audioglass feasibility exploration

Investigated 2026-10-02. Historical architecture proposal. As of 2026-10-07, the app has live system/per-app capture, a separate hardware input path, all six OpenMeters processors, native AppKit plots and a Metal spectrogram. See README.md and HANDOVER.md for the current implementation, validation, and remaining feature work; the experiments below describe the earlier exploration.

Audioglass can be a conventional macOS window containing audio meters over a glass material. Window behavior, background material, capture, analysis, and rendering can be implemented independently. Glass does not require a floating overlay.

## Native window and appearance

Use a normal AppKit `NSWindow`, with SwiftUI for controls and settings if convenient. Keep the titled, closable, miniaturizable, and resizable style flags, standard traffic lights, normal window level, a real drag region, and normal application activation. A transparent title bar and full-size content view can make the chrome quiet while preserving native window behavior.

Let macOS handle edge/corner tiling and the green-button window controls. Full-screen Split View is a separate behavior from desktop tiling; `fullScreenAllowsTiling` concerns the former. Neither needs a custom snapping implementation. Avoid a fixed aspect ratio or a large minimum size that prevents narrow tiles. Verify desktop tiling, Window menu actions, minimizing, Mission Control, Stage Manager, and multi-display restoration in a runnable prototype.

Scrap's local implementation is a useful reference:

- [Scrap's ContentView.swift](/Users/cillian/Development/tools/Scrap/Scrap/Scrap/ContentView.swift): `WindowConfigurator` preserves a regular window, makes its title bar transparent, and selects a background material.
- Its `GlassNSView` uses public `NSGlassEffectView` on macOS 26+.
- Its `VisualEffectView` provides an `NSVisualEffectView` behind-window material.
- Scrap also contains a private CoreGraphics blur fallback for older systems. Audioglass can begin with the public material views instead.

Start by comparing Liquid Glass against quieter frosted material. A dark tint beneath the plots may make labels and traces easier to read. Keep the meter layer itself transparent; making the entire window translucent would also dim the meters. Spectrogram pixels may intentionally be opaque while surrounding plots and gutters reveal glass. Honor Reduce Transparency.

## What OpenMeters supplies

Inspected upstream commit `c488209234c617199d362e952d350f96a6a769d7`, version 1.15.2.

The repository is a Linux application, not a ready-made macOS meter library. Its manifest includes PipeWire, Wayland, a layer-shell integration, Iced, and a Vulkan-only wgpu configuration. Simply embedding its executable is not a practical route.

The useful separation is inside `src/visuals/`: loudness, spectrum, spectrogram, waveform, oscilloscope, and stereometer each have a processor distinct from view state and rendering. The processors accept an `AudioBlock` and produce snapshots or updates. `src/dsp.rs` and `src/util/audio/` contain shared analysis helpers.

The extraction still needs a supported library interface. Some methods have crate-restricted visibility; `meter.rs` currently imports the PipeWire transport; the visual manager, view state, configuration, and renderer have additional coupling. Retain a pinned upstream reference and attribution so updates can be reviewed deliberately.

Local feasibility check: copied all six `processor.rs` files, shared DSP/audio utilities, and macros into a temporary library at `/tmp/audioglass-dsp-probe`. Removed the unused `util::color` module from that harness because it imports Iced; left the processor algorithms unchanged. Added serde, rustfft, realfft, bytemuck, and the existing ebur128 test dependency. On this Mac with Rust 1.94, the extracted library compiled and all 66 included upstream tests passed. These are the selected modules' tests, not the full application suite; this does not validate a Swift bridge, renderer, capture backend, or runtime performance. The full upstream manifest currently requires Rust 1.95.

The existing render code uses Iced types and `iced_wgpu` primitives. Its WGSL shaders and geometry algorithms are potentially reusable, but not directly embeddable as an `NSView`.

## Proposed architecture

```text
Core Audio process tap / input device
                |
    preallocated audio transport
                |
   OpenMeters Rust DSP on a worker
                |
      bounded display snapshots
                |
 GPU meter view in a native glass NSWindow
```

Use a small C ABI around a Rust static library. Keep buffers, lifetimes, configuration changes, and error reporting explicit. The capture callback should only copy into preallocated transport; do FFTs, allocations, and snapshot construction on a worker. Handle capture gaps and format changes explicitly. Refresh plots independently of audio processing, and reduce rendering when the window is hidden or minimized.

For system output, investigate Apple's Core Audio process taps first: macOS 14.2+, system/per-process capture, and a system audio recording permission prompt. Ordinary microphone or audio interface inputs need a separate device capture path. Do not mute or reroute the monitored output. Test permissions, output-device changes, and DAW playback in an actual bundled app.

Two reasonable rendering routes:

| Route | Benefit | Cost |
| --- | --- | --- |
| Adapt OpenMeters wgpu renderer to a native view, enable Metal | Retains more shaders and visual behavior | Remove Iced coupling; prove transparent compositing and surface lifetime |
| Render DSP snapshots with native Metal/MetalKit | Direct AppKit integration and layout control | Reimplement plots, labels, interaction, and GPU history management |

Recommendation: keep capture and windowing native; retain the Rust DSP; compare the renderer routes using one spectrum plot before committing. wgpu itself supports Metal and translates WGSL, so retaining its shader work is technically plausible.

## Responsive layouts

Offer horizontal, vertical, and automatic arrangements. A shallow wide window can show a strip; a narrow tall window can stack plots; a large window can use a grid. Reflow the panels while preserving meaningful frequency/time axes. Use preferred panel sizes and adjustable dividers rather than one fixed global ratio. Keep an explicit orientation override so resizing does not surprise the user.

macOS half/quarter tiling does not mean an arbitrary 100-pixel-high docked strip. A normal window can be resized to a shallow strip, while system tiling remains available for halves and quarters. This distinction is worth testing against the desired daily workflow.

## Suggested first experiments

1. A native material window with animated sample traces: prove edge resizing, all tiling positions, compact chrome, and horizontal/vertical reflow.
2. One real OpenMeters spectrum processor fed a known signal: validate the Rust bridge and rendering approach.
3. Live system audio through a process tap: verify permission and device lifecycle without disrupting playback.
4. Add remaining meters, persistent layouts, and native settings after the boundaries work.

OpenMeters declares GPL-3.0-or-later. Treat reuse as a GPL project direction; resolve distribution/license requirements before a release.

## Sources

- [OpenMeters repository](https://github.com/httpsworldview/openmeters)
- [Pinned dependency manifest](https://github.com/httpsworldview/openmeters/blob/c488209234c617199d362e952d350f96a6a769d7/Cargo.toml)
- [Apple: Tile windows on Mac](https://support.apple.com/en-hk/guide/mac-help/mchlef287e5d/mac)
- [Apple: NSWindow](https://developer.apple.com/documentation/appkit/nswindow)
- [Apple: NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Apple: NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [wgpu 27.0.1: Metal backend and WGSL support](https://docs.rs/wgpu/27.0.1/wgpu/)
