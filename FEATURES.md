# Feature completeness tracking

Reviewed 2026-10-08. This table describes implemented behavior, not a declaration of feature parity. The visual target remains native macOS glass, white traces, and ordinary window management.

References:

- OpenMeters 1.15.2 at commit `c488209234c617199d362e952d350f96a6a769d7`: https://github.com/httpsworldview/openmeters/tree/c488209234c617199d362e952d350f96a6a769d7
- Current MiniMeters feature list: https://minimeters.app/
- Apple process tap sample: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

| Area | Implemented | Remaining |
| --- | --- | --- |
| Live capture | Unmuted system and app taps; native source menu; float32 hardware input path; bounded stereo transport | Validate input permissions/real hardware, disconnection, output/sample-rate changes; selectable interface channel pair; device conversion where required; robust consent/silence feedback |
| Spectrum | Upstream FFT; 4 sizes; Mid/Side/L/R; optional dimmer second trace (upstream secondary source); raw/exponential/peak averaging; A-weighting; 3 dB ranges; linear/log/ERB axis; optional peak label; cursor Hz/note/cents/dB for both traces; click-and-hold freeze | Window choice, bar display, richer axis labels |
| Oscilloscope | Upstream stable and zero-crossing triggers; 1/2/4 cycles; own channel (no longer shared with spectrum), optional second channel, trigger source, 10–100 ms capture length; overlaid or stacked; persistence trails; cursor readouts per trace; optional display normalization | Manual gain |
| Spectrogram | Upstream reassigned (default) and classic FFT; reassigned power accumulation with time offsets at physical-pixel frequency resolution; one column per point; native Metal ring texture with incremental uploads; FFT 1024–16384, hop divisor, window, zero padding, linear/log/ERB scale, floor, spectral tilt, scroll-left/waterfall orientations, glass/heat palettes, all persisted; history re-rendered on resize; cursor Hz/age/dB | Frequency axis labels, zoom/pan, piano-roll overlay; sustained performance benchmark at large sizes |
| Waveform | Upstream min/max history; any of L/R/M/S for one or two lanes; 3 durations; optional fast/slow full-band RMS envelope from upstream band history (band analysis only runs while shown); cursor min/max/peak/RMS; optional shared display normalization | Band-colour modes, zoom/scroll |
| Stereo | Upstream L/R snapshots; Lissajous or dot cloud; upstream linear or scaled radial projection with dB guides; three rotations and L/R flip; full-band correlation bar or low/mid/high correlation (band analysis only when selected); optional radial normalization (linear) | Unipolar view, band-coloured points |
| Loudness | Upstream momentary and short-term LUFS; fast or slow RMS L/R; true peaks with display decay; true-peak hold (3 s, 10 s, until clicked) from exact per-read maxima; CLIP badge above 0 dBTP; click readout to reset | Calibrated scale |
| VU | Not implemented | MiniMeters' seventh module; calibrated ballistics and reference-level controls |
| Native window | Glass, hidden title, traffic lights, normal level, edge resizing, tiling eligibility, strip/column sizes; automatic/manual layouts; small-window scrolling; Shift-drag section resizing; top-bar dragging; left loudness/audio column; full-height interactive meters; native Settings (⌘,) with visibility and ordering controls; persisted display-synchronized 60/120 fps selection | Full Ableton pairing/position-swap/corner-tiling matrix; edge/corner drag coverage; scroll/resize polish; separate meter windows |
| Persistence | Source, meters, arrangement, analysis settings, saved frame, independent horizontal/vertical section sizes and module order | Presets/import/export and broader settings UI |
| Recording/clipping | Not implemented | Local rolling audio buffer, 10/60-second export, recording UI |
| DAW integration | Captures Ableton output through native process tap | Audio sender plug-in and AU/VST3/CLAP products; do not treat native tap as equivalent to DAW bus capture |
| Packaging | Local bundle/signing, usage strings, About panel, GPL/attribution resources | App icon, release build/distribution/signing/notarization if requested; no deployment authorized |

## Renderer decision

Upstream combines Iced/wgpu rendering with its UI stack and enables only Vulkan in its pinned Cargo configuration. Enabling Metal there is feasible, but porting its renderer entails adapting pipeline/state/host integration. Audioglass uses AppKit for white line plots, grids, and labels and a small native Metal pipeline for the spectrogram texture. This preserves the native window and avoids including a second windowing stack. It is an architectural comparison, not a comparative performance benchmark. Reassigned spectrogram rasterization follows upstream's accumulation rules on the CPU; differences are listed in `Rust/UPSTREAM.md`.
