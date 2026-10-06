# Feature completeness tracking

Reviewed 2026-10-07. This table describes implemented behavior, not a declaration of feature parity. The visual target remains native macOS glass, white traces, and ordinary window management.

References:

- OpenMeters 1.15.2 at commit `c488209234c617199d362e952d350f96a6a769d7`: https://github.com/httpsworldview/openmeters/tree/c488209234c617199d362e952d350f96a6a769d7
- Current MiniMeters feature list: https://minimeters.app/
- Apple process tap sample: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

| Area | Implemented | Remaining |
| --- | --- | --- |
| Live capture | Unmuted system and app taps; native source menu; float32 hardware input path; bounded stereo transport | Validate input permissions/real hardware, disconnection, output/sample-rate changes; selectable interface channel pair; device conversion where required; robust consent/silence feedback |
| Spectrum | Upstream FFT; 4 sizes; Mid/Side/L/R; raw/exponential/peak averaging; A-weighting; 3 dB ranges; white asinh trace; cursor Hz/note/cents/dB/channel | Independent secondary trace, window choice, axis modes, richer axis labels, further upstream controls; MiniMeters target-curve import |
| Oscilloscope | Upstream stable and zero-crossing triggers; 1/2/4 cycles; Mid/Side/L/R; cursor time/amplitude/dBFS/pitch lock | Independent second trace/trigger source, gain/time controls, further upstream display settings |
| Spectrogram | Upstream classic FFT; grayscale native Metal history, bounded log-frequency raster; cursor Hz/note/age/approximate row-peak dB | Reassignment rasterization including time offsets/power accumulation; FFT/window/hop/history controls; orientation, range, palette and axis settings; fidelity/performance comparison |
| Waveform | Upstream stereo min/max history; 3 durations; cursor age/channel/min/max/peak dBFS | Band analysis/history overlays, selectable derived channels, gain; richer zoom/scroll controls |
| Stereo | Upstream L/R snapshots and full-band correlation | Scaling/Lissajous modes, band overlays/correlation, gain/persistence controls |
| Loudness | Upstream momentary and short-term LUFS; fast RMS L/R; true peaks with display decay | Slow RMS/mode selection, peak hold/clip indicators, calibrated scale and richer display controls |
| VU | Not implemented | MiniMeters' seventh module; calibrated ballistics and reference-level controls |
| Native window | Glass, hidden title, traffic lights, normal level, edge resizing, tiling eligibility, strip/column sizes; automatic/manual layouts; small-window scrolling | Full Ableton pairing/position-swap/corner-tiling matrix; edge/corner drag coverage; scroll/resize polish; meter reordering/resizing and separate meter windows |
| Persistence | Source, meters, arrangement, analysis settings, saved frame | Presets/import/export and broader settings UI |
| Recording/clipping | Not implemented | Local rolling audio buffer, 10/60-second export, recording UI |
| DAW integration | Captures Ableton output through native process tap | Audio sender plug-in and AU/VST3/CLAP products; do not treat native tap as equivalent to DAW bus capture |
| Packaging | Local bundle/signing, usage strings, About panel, GPL/attribution resources | App icon, release build/distribution/signing/notarization if requested; no deployment authorized |

## Renderer decision

Upstream combines Iced/wgpu rendering with its UI stack and enables only Vulkan in its pinned Cargo configuration. Enabling Metal there is feasible, but porting its renderer entails adapting pipeline/state/host integration. Audioglass uses AppKit for white line plots, grids, and labels and a small native Metal pipeline for the spectrogram texture. This preserves the native window and avoids including a second windowing stack. It is an architectural comparison, not a comparative performance benchmark. Reassigned spectrogram rasterization still needs to respect the upstream algorithm and accumulation rules before it can be exposed as an equivalent mode.
