# Feature completeness tracking

Reviewed 2026-10-08. This table describes implemented behavior, not a declaration of feature parity. The visual target remains native macOS glass, white traces, and ordinary window management.

References:

- OpenMeters 1.15.2 at commit `c488209234c617199d362e952d350f96a6a769d7`: https://github.com/httpsworldview/openmeters/tree/c488209234c617199d362e952d350f96a6a769d7
- Current MiniMeters feature list: https://minimeters.app/
- Apple process tap sample: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

| Area | Implemented | Remaining |
| --- | --- | --- |
| Live capture | Unmuted system and app taps; native source menu; float32 hardware input path; bounded stereo transport | Validate input permissions/real hardware, disconnection, output/sample-rate changes; selectable interface channel pair; device conversion where required; robust consent/silence feedback |
| Spectrum | Upstream FFT; 4 sizes; Mid/Side/L/R; raw/exponential/peak averaging; A-weighting; 3 dB ranges; white asinh trace; cursor Hz/note/cents/dB/channel; click-and-hold trace/readout freeze | Independent secondary trace, window choice, axis modes, richer axis labels, further upstream controls; MiniMeters target-curve import |
| Oscilloscope | Upstream stable and zero-crossing triggers; 1/2/4 cycles; Mid/Side/L/R; cursor time/amplitude/dBFS/pitch lock; optional display normalization | Independent second trace/trigger source, gain/time controls, further upstream display settings |
| Spectrogram | Upstream reassigned (default) and classic FFT; reassigned power accumulation with time offsets at physical-pixel frequency resolution; one column per point; native Metal ring texture with incremental uploads; FFT 1024–16384, hop divisor, window, zero padding, linear/log/ERB scale, floor, spectral tilt, scroll-left/waterfall orientations, glass/heat palettes, all persisted; history re-rendered on resize; cursor Hz/age/dB | Frequency axis labels, zoom/pan, piano-roll overlay; sustained performance benchmark at large sizes |
| Waveform | Upstream stereo min/max history; 3 durations; cursor age/channel/min/max/peak dBFS; optional shared stereo display normalization | Band analysis/history overlays, selectable derived channels, gain; richer zoom/scroll controls |
| Stereo | Upstream L/R snapshots and full-band correlation; optional radial display normalization with shared L/R gain | Scaling/Lissajous modes, band overlays/correlation, gain/persistence controls |
| Loudness | Upstream momentary and short-term LUFS; fast RMS L/R; true peaks with display decay | Slow RMS/mode selection, peak hold/clip indicators, calibrated scale and richer display controls |
| VU | Not implemented | MiniMeters' seventh module; calibrated ballistics and reference-level controls |
| Native window | Glass, hidden title, traffic lights, normal level, edge resizing, tiling eligibility, strip/column sizes; automatic/manual layouts; small-window scrolling; Shift-drag section resizing; top-bar dragging; left loudness/audio column; full-height interactive meters; native Settings (⌘,) with visibility and ordering controls; persisted display-synchronized 60/120 fps selection | Full Ableton pairing/position-swap/corner-tiling matrix; edge/corner drag coverage; scroll/resize polish; separate meter windows |
| Persistence | Source, meters, arrangement, analysis settings, saved frame, independent horizontal/vertical section sizes and module order | Presets/import/export and broader settings UI |
| Recording/clipping | Not implemented | Local rolling audio buffer, 10/60-second export, recording UI |
| DAW integration | Captures Ableton output through native process tap | Audio sender plug-in and AU/VST3/CLAP products; do not treat native tap as equivalent to DAW bus capture |
| Packaging | Local bundle/signing, usage strings, About panel, GPL/attribution resources | App icon, release build/distribution/signing/notarization if requested; no deployment authorized |

## Renderer decision

Upstream combines Iced/wgpu rendering with its UI stack and enables only Vulkan in its pinned Cargo configuration. Enabling Metal there is feasible, but porting its renderer entails adapting pipeline/state/host integration. Audioglass uses AppKit for white line plots, grids, and labels and a small native Metal pipeline for the spectrogram texture. This preserves the native window and avoids including a second windowing stack. It is an architectural comparison, not a comparative performance benchmark. Reassigned spectrogram rasterization follows upstream's accumulation rules on the CPU; differences are listed in `Rust/UPSTREAM.md`.
