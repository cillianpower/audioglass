// SPDX-License-Identifier: GPL-3.0-or-later
mod macros;
pub mod dsp;
pub mod util;
pub mod visuals;
pub mod spectrogram_raster;

use std::collections::VecDeque;
use visuals::waveform::processor::{WaveformConfig, WaveformProcessor};
use visuals::spectrogram::processor::{SpectrogramConfig, SpectrogramProcessor};
use spectrogram_raster::{Geometry, SpectrogramRaster};
use visuals::stereometer::processor::{StereometerConfig, StereometerProcessor};
use visuals::loudness::processor::{LoudnessConfig, LoudnessProcessor};

use dsp::{AudioBlock, ChannelPosition, MAX_AUDIO_CHANNELS};
use util::audio::{Channel, FrequencyScale, WindowKind, DB_FLOOR};
use visuals::oscilloscope::processor::{OscilloscopeConfig, OscilloscopeProcessor, TriggerMode};
use visuals::spectrum::processor::{AveragingMode, SpectrumConfig, SpectrumProcessor};

pub struct Engine {
    history: WaveformProcessor,
    spectrogram: SpectrogramProcessor,
    stereo: StereometerProcessor,
    loudness: LoudnessProcessor,
    history_columns: VecDeque<[f32; WAVE_STRIDE]>,
    raster: SpectrogramRaster,
    stereo_points: Vec<f32>,
    metrics: [f32; METRIC_COUNT],
    options: MeterOptions,
    sample_rate: f32,
    scope_duration: f32,
    scope_cycle_hz: f32,
    weighted: bool,
    spectrum: SpectrumProcessor,
    scope: OscilloscopeProcessor,
    smoothing: f32,
    frequencies: Vec<f32>,
    levels: Vec<f32>,
    secondary_levels: Vec<f32>,
    waveform: Vec<f32>,
    waveform2: Vec<f32>,
}

/// Per column: channel 1 min/max, channel 2 min/max, channel 1/2 RMS amplitude.
pub const WAVE_STRIDE: usize = 6;
/// M, S, RMS fast L/R, displayed true peak L/R, correlation full/low/mid/high,
/// RMS slow L/R, true peak maximum L/R since the previous read.
pub const METRIC_COUNT: usize = 14;
const TRUE_PEAK_MAX: usize = 12;

#[repr(C)]
pub struct FrameCounts { pub spectrum_count: i32, pub scope_count: i32, pub secondary_count: i32, pub scope2_count: i32 }

/// Channel codes: 0 none, 1 mid, 2 side, 3 left, 4 right.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MeterOptions {
    pub spectrum_secondary: i32,
    pub scope_channel: i32,
    pub scope_channel2: i32,
    /// 0 follows channel 1.
    pub scope_trigger: i32,
    pub scope_duration_ms: i32,
    pub waveform_channel1: i32,
    pub waveform_channel2: i32,
    /// 0 off, 1 fast, 2 slow.
    pub waveform_rms: i32,
    pub stereo_bands: i32,
}

impl Default for MeterOptions {
    fn default() -> Self {
        Self { spectrum_secondary: 0, scope_channel: 1, scope_channel2: 0, scope_trigger: 0, scope_duration_ms: 50,
            waveform_channel1: 3, waveform_channel2: 4, waveform_rms: 0, stereo_bands: 0 }
    }
}

fn channel(code: i32) -> Channel {
    match code { 1 => Channel::Mid, 2 => Channel::Side, 3 => Channel::Left, 4 => Channel::Right, _ => Channel::None }
}

/// Index into upstream's derived waveform channels (L, R, M, S).
fn waveform_index(code: i32) -> Option<usize> {
    match code { 3 => Some(0), 4 => Some(1), 1 => Some(2), 2 => Some(3), _ => None }
}

#[unsafe(no_mangle)]
pub extern "C" fn ag_create() -> *mut Engine {
    let mut raster = SpectrogramRaster::default();
    raster.set_lag(SpectrogramConfig::default().fft_size / 2 / SpectrogramConfig::default().hop_size);
    Box::into_raw(Box::new(Engine {
        history: WaveformProcessor::new(WaveformConfig { analyze_bands: false, ..WaveformConfig::default() }),
        // Upstream drops columns beyond history_length within one block.
        spectrogram: SpectrogramProcessor::new(SpectrogramConfig {
            history_length: spectrogram_raster::MAX_COLUMNS, ..SpectrogramConfig::default()
        }),
        stereo: StereometerProcessor::new(StereometerConfig::default()),
        loudness: LoudnessProcessor::new(LoudnessConfig::default()),
        history_columns: VecDeque::with_capacity(1024),
        raster,
        stereo_points: Vec::new(),
        metrics: [-120.0, -120.0, -120.0, -120.0, -120.0, -120.0, 0.0, 0.0, 0.0, 0.0, -120.0, -120.0, -120.0, -120.0],
        options: MeterOptions::default(),
        sample_rate: 48000.0, scope_duration: 0.0, scope_cycle_hz: 0.0, weighted: false,
        spectrum: SpectrumProcessor::new(SpectrumConfig {
            secondary_source: Channel::None, ..SpectrumConfig::default()
        }),
        scope: OscilloscopeProcessor::new(OscilloscopeConfig::default()),
        smoothing: 0.0,
        frequencies: Vec::new(), levels: Vec::new(), secondary_levels: Vec::new(),
        waveform: Vec::new(), waveform2: Vec::new(),
    }))
}

/// Caller owns the handle and must serialize calls and destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_destroy(engine: *mut Engine) {
    if !engine.is_null() { unsafe { drop(Box::from_raw(engine)); } }
}

/// Settings are applied on the analysis worker before PCM ingestion.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_configure(engine: *mut Engine, channel: i32, fft_size: i32,
    weighted: i32, floor_db: f32, trigger_cycles: i32, wave_speed: f32, smoothing: f32) {
    if engine.is_null() { return; }
    let e = unsafe { &mut *engine };
    let source = match channel { 1 => Channel::Side, 2 => Channel::Left, 3 => Channel::Right, _ => Channel::Mid };
    let fft_size = match fft_size { 4096 | 8192 | 16384 | 32768 => fft_size as usize, _ => 16384 };
    let smoothing = if smoothing == -1.0 { -1.0 } else if smoothing.is_finite() { smoothing.clamp(0.0, 0.95) } else { 0.0 };
    e.smoothing = smoothing;
    e.weighted = weighted != 0;
    e.spectrum.update_config(SpectrumConfig {
        source, fft_size, hop_size: fft_size / 16,
        floor_db: if floor_db.is_finite() { floor_db.clamp(-120.0, -12.0) } else { -120.0 },
        averaging: if smoothing == -1.0 { AveragingMode::PeakHold { decay_per_second: 12.0 } }
            else if smoothing == 0.0 { AveragingMode::None }
            else { AveragingMode::Exponential { factor: smoothing } },
        ..e.spectrum.config()
    });
    e.scope.update_config(OscilloscopeConfig {
        trigger_mode: if trigger_cycles == 0 { TriggerMode::ZeroCrossing }
            else { TriggerMode::Stable { num_cycles: trigger_cycles.clamp(1, 4) as usize } },
        ..e.scope.config()
    });
    let speed = if wave_speed.is_finite() { wave_speed.clamp(100.0, 400.0) } else { 200.0 };
    if speed != e.history.config().scroll_speed {
        e.history_columns.clear();
        e.history.reset_audio();
        e.history.update_config(WaveformConfig { scroll_speed: speed, ..e.history.config() });
    }
}

/// Display options beyond `ag_configure`; unchanged values leave processors alone.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_configure_options(engine: *mut Engine, options: *const MeterOptions) {
    if engine.is_null() || options.is_null() { return; }
    let e = unsafe { &mut *engine };
    let mut o = unsafe { *options };
    if channel(o.scope_channel) == Channel::None { o.scope_channel = 1; }
    if waveform_index(o.waveform_channel1).is_none() { o.waveform_channel1 = 3; }
    o.scope_duration_ms = o.scope_duration_ms.clamp(5, 200);
    o.waveform_rms = o.waveform_rms.clamp(0, 2);
    let previous = std::mem::replace(&mut e.options, o);
    e.spectrum.update_config(SpectrumConfig { secondary_source: channel(o.spectrum_secondary), ..e.spectrum.config() });
    if channel(o.spectrum_secondary) == Channel::None { e.secondary_levels.clear(); }
    e.scope.update_config(OscilloscopeConfig {
        channel_1: channel(o.scope_channel), channel_2: channel(o.scope_channel2),
        trigger_source: channel(o.scope_trigger), segment_duration: o.scope_duration_ms as f32 / 1000.0,
        ..e.scope.config()
    });
    if (previous.waveform_channel1, previous.waveform_channel2, previous.waveform_rms != 0)
        != (o.waveform_channel1, o.waveform_channel2, o.waveform_rms != 0) {
        e.history_columns.clear();
        e.history.reset_audio();
        // Band analysis (and its cost) only runs while the RMS overlay is shown.
        e.history.update_config(WaveformConfig { analyze_bands: o.waveform_rms != 0, track_history: o.waveform_rms != 0,
            ..e.history.config() });
    }
    if previous.stereo_bands != o.stereo_bands {
        e.stereo.update_config(StereometerConfig { analyze_bands: o.stereo_bands != 0, ..e.stereo.config() });
    }
}

/// Interleaved stereo PCM. Caller serializes ingestion, snapshots, and destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_ingest(engine: *mut Engine, pcm: *const f32, frames: i32, sample_rate: f32) {
    if engine.is_null() || pcm.is_null() || frames <= 0 || frames > 262144
        || !sample_rate.is_finite() || !(8000.0..=384000.0).contains(&sample_rate) { return; }
    let e = unsafe { &mut *engine };
    let samples = unsafe { std::slice::from_raw_parts(pcm, frames as usize * 2) };
    let mut positions = [ChannelPosition::Unknown; MAX_AUDIO_CHANNELS];
    positions[0] = ChannelPosition::FrontLeft;
    positions[1] = ChannelPosition::FrontRight;
    let block = AudioBlock::with_positions(samples, 2, sample_rate, positions);
    e.sample_rate = sample_rate;
    let update = e.history.process_block(&block);
    if update.reset { e.history_columns.clear(); }
    let first = waveform_index(e.options.waveform_channel1).unwrap_or(0);
    let second = waveform_index(e.options.waveform_channel2);
    let window = (e.options.waveform_rms.max(1) - 1) as usize;
    // Full-band RMS: the crossover bands' mean powers sum to the signal's.
    let rms = |column: &visuals::waveform::processor::WaveColumn| {
        let power: f32 = column.rms_db[window].iter().filter(|db| **db > DB_FLOOR)
            .map(|db| 10f32.powf(db / 10.0)).sum();
        power.sqrt()
    };
    for columns in update.columns {
        if e.history_columns.len() == 1024 { e.history_columns.pop_front(); }
        let a = &columns[first];
        let b = second.map(|index| &columns[index]);
        e.history_columns.push_back([a.min, a.max, b.map_or(0.0, |b| b.min), b.map_or(0.0, |b| b.max),
            if e.options.waveform_rms != 0 { rms(a) } else { 0.0 },
            if e.options.waveform_rms != 0 { b.map_or(0.0, rms) } else { 0.0 }]);
    }
    if let Some(update) = e.spectrogram.process_block(&block) { e.raster.push(update); }
    if let Some(snapshot) = e.stereo.process_block(&block) {
        e.stereo_points.clear();
        for &(left, right) in snapshot.points[0].iter() { e.stereo_points.extend([left, right]); }
        e.metrics[6..10].copy_from_slice(&snapshot.correlations);
    }
    let loudness = e.loudness.process_block(&block);
    let previous = e.metrics;
    e.metrics[..6].copy_from_slice(&[loudness.momentary_loudness, loudness.short_term_loudness,
        loudness.rms_fast_db[0], loudness.rms_fast_db[1],
        loudness.true_peak_db[0].max(previous[4] - frames as f32 / sample_rate * 20.0),
        loudness.true_peak_db[1].max(previous[5] - frames as f32 / sample_rate * 20.0)]);
    e.metrics[10..12].copy_from_slice(&loudness.rms_slow_db[..2]);
    for channel in 0..2 {
        e.metrics[TRUE_PEAK_MAX + channel] = e.metrics[TRUE_PEAK_MAX + channel].max(loudness.true_peak_db[channel]);
    }
    if let Some(snapshot) = e.spectrum.process_block(&block) {
        e.frequencies.clone_from(&snapshot.frequency_bins);
        // Upstream stores A-weighted first, unweighted/raw second.
        let trace = if e.weighted { 0 } else { 1 };
        e.levels.clone_from(&snapshot.traces[0][trace]);
        if channel(e.options.spectrum_secondary) != Channel::None {
            e.secondary_levels.clone_from(&snapshot.traces[1][trace]);
        }
    }
    if let Some(snapshot) = e.scope.process_block(&block) {
        e.scope_duration = snapshot.duration_seconds;
        e.scope_cycle_hz = snapshot.cycle_hz.unwrap_or(0.0);
        let n = snapshot.samples_per_channel;
        e.waveform.clear();
        e.waveform2.clear();
        for trace in 0..snapshot.channels {
            let samples = &snapshot.samples[trace * n..(trace + 1) * n];
            match snapshot.slots[trace] { 0 => e.waveform.extend_from_slice(samples), _ => e.waveform2.extend_from_slice(samples) }
        }
    }
 }

/// Buffers must be writable for their capacities and cannot alias the handle.
/// Returns the latest snapshots; ingestion and reads must be serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_process(
    engine: *mut Engine, smoothing: f32,
    frequencies: *mut f32, levels: *mut f32, secondary: *mut f32, spectrum_capacity: i32,
    waveform: *mut f32, waveform2: *mut f32, scope_capacity: i32,
) -> FrameCounts {
    let empty = FrameCounts { spectrum_count: 0, scope_count: 0, secondary_count: 0, scope2_count: 0 };
    if engine.is_null() || frequencies.is_null() || levels.is_null() || waveform.is_null()
        || secondary.is_null() || waveform2.is_null()
        || spectrum_capacity <= 0 || scope_capacity <= 0 { return empty; }
    let e = unsafe { &mut *engine };
    let smoothing = if smoothing == -1.0 { -1.0 } else if smoothing.is_finite() { smoothing.clamp(0.0, 0.95) } else { 0.0 };
    if smoothing != e.smoothing {
        e.smoothing = smoothing;
        e.spectrum.update_config(SpectrumConfig {
            averaging: if smoothing == -1.0 { AveragingMode::PeakHold { decay_per_second: 12.0 } }
                else if smoothing == 0.0 { AveragingMode::None }
                else { AveragingMode::Exponential { factor: smoothing } },
            ..e.spectrum.config()
        });
    }
    let spectrum_count = e.frequencies.len().min(e.levels.len()).min(spectrum_capacity as usize);
    let scope_count = e.waveform.len().min(scope_capacity as usize);
    let secondary_count = e.secondary_levels.len().min(spectrum_count);
    let scope2_count = e.waveform2.len().min(scope_capacity as usize);
    unsafe {
        std::ptr::copy_nonoverlapping(e.frequencies.as_ptr(), frequencies, spectrum_count);
        std::ptr::copy_nonoverlapping(e.levels.as_ptr(), levels, spectrum_count);
        std::ptr::copy_nonoverlapping(e.secondary_levels.as_ptr(), secondary, secondary_count);
        std::ptr::copy_nonoverlapping(e.waveform.as_ptr(), waveform, scope_count);
        std::ptr::copy_nonoverlapping(e.waveform2.as_ptr(), waveform2, scope2_count);
    }
    FrameCounts { spectrum_count: spectrum_count as i32, scope_count: scope_count as i32,
        secondary_count: secondary_count as i32, scope2_count: scope2_count as i32 }
}

/// Fixed-capacity supplementary snapshot: 1024 waveform columns of WAVE_STRIDE,
/// stereo L/R pairs, METRIC_COUNT metrics. True peak maxima restart after each read.
/// All buffers must have the documented capacities and be disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_read_meters(engine: *mut Engine, wave: *mut f32, stereo: *mut f32,
    metrics: *mut f32, counts: *mut i32) {
    if engine.is_null() || wave.is_null() || stereo.is_null() || metrics.is_null()
        || counts.is_null() { return; }
    let e = unsafe { &mut *engine };
    unsafe {
        for (i, column) in e.history_columns.iter().enumerate() {
            std::ptr::copy_nonoverlapping(column.as_ptr(), wave.add(i * WAVE_STRIDE), WAVE_STRIDE);
        }
        std::ptr::copy_nonoverlapping(e.stereo_points.as_ptr(), stereo, e.stereo_points.len());
        std::ptr::copy_nonoverlapping(e.metrics.as_ptr(), metrics, METRIC_COUNT);
        *counts = e.history_columns.len() as i32;
        *counts.add(1) = (e.stereo_points.len() / 2) as i32;
    }
    e.metrics[TRUE_PEAK_MAX..].fill(-120.0);
}

/// Five floats: sample rate, scope duration, locked cycle Hz (0 = unlocked),
/// spectrogram seconds per column, populated spectrogram column count.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_read_timing(engine: *mut Engine, timing: *mut f32) {
    if engine.is_null() || timing.is_null() { return; }
    let e = unsafe { &*engine };
    let values = [e.sample_rate, e.scope_duration, e.scope_cycle_hz,
        e.spectrogram.config().hop_size as f32 / e.sample_rate,
        e.raster.populated() as f32];
    unsafe { std::ptr::copy_nonoverlapping(values.as_ptr(), timing, 5); }
}

/// Spectrogram analysis and display geometry. Analysis changes clear history;
/// geometry changes re-render retained history. `columns` is the time extent in
/// points, `rows` the frequency extent in pixels, `row_span` pixels per point.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_configure_spectrogram(engine: *mut Engine, fft_size: i32, hop_divisor: i32,
    window: i32, reassign: i32, zero_padding: i32, scale: i32, columns: i32, rows: i32, row_span: i32) {
    if engine.is_null() { return; }
    let e = unsafe { &mut *engine };
    let fft_size = match fft_size { 1024 | 2048 | 4096 | 8192 | 16384 => fft_size as usize, _ => 4096 };
    let divisor = match hop_divisor { 4 | 6 | 8 | 16 | 32 | 64 | 128 => hop_divisor as usize, _ => 16 };
    let window = match window { 0 => WindowKind::Rectangular, 2 => WindowKind::Hamming, 3 => WindowKind::Blackman,
        4 => WindowKind::BlackmanHarris, _ => WindowKind::Hann };
    let zero_padding = match zero_padding { 2 | 4 | 8 => zero_padding as usize, _ => 1 };
    let current = e.spectrogram.config();
    let config = SpectrogramConfig { fft_size, hop_size: (fft_size / divisor).max(1), window,
        use_reassignment: reassign != 0, zero_padding_factor: zero_padding, ..current };
    if (config.fft_size, config.hop_size, config.window, config.use_reassignment, config.zero_padding_factor)
        != (current.fft_size, current.hop_size, current.window, current.use_reassignment, current.zero_padding_factor) {
        e.spectrogram.update_config(config);
        e.raster.clear();
        // Upstream centres reassigned points half a window before the column.
        e.raster.set_lag(if config.use_reassignment { fft_size / 2 / config.hop_size } else { 0 });
    }
    e.raster.set_geometry(Geometry {
        columns: columns.max(1) as usize, rows: rows.max(1) as usize, row_span: row_span.max(1) as usize,
        scale: match scale { 0 => FrequencyScale::Linear, 2 => FrequencyScale::Erb, _ => FrequencyScale::Logarithmic },
    });
}

/// Describes the next spectrogram read: reset flag, ring columns, rows, first
/// absolute column, column count, columns produced. Returns floats required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_spectrogram_pending(engine: *mut Engine, info: *mut i64) -> i64 {
    if engine.is_null() || info.is_null() { return 0; }
    let p = unsafe { &*engine }.raster.pending();
    let values = [i64::from(p.reset), p.columns as i64, p.rows as i64, p.first as i64, p.count as i64, p.produced as i64];
    unsafe { std::ptr::copy_nonoverlapping(values.as_ptr(), info, 6); }
    (p.count * p.rows) as i64
}

/// Writes pending columns (oldest first, `rows` dB values each, lowest frequency
/// first, -1000 when empty) and marks them delivered. Fills `info` as above;
/// writes nothing and reports zero columns when `capacity` is too small.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ag_spectrogram_read(engine: *mut Engine, values: *mut f32, capacity: i64, info: *mut i64) {
    if engine.is_null() || values.is_null() || info.is_null() || capacity < 0 { return; }
    let e = unsafe { &mut *engine };
    let output = unsafe { std::slice::from_raw_parts_mut(values, capacity as usize) };
    let p = e.raster.read(output);
    let values = [i64::from(p.reset), p.columns as i64, p.rows as i64, p.first as i64, p.count as i64, p.produced as i64];
    unsafe { std::ptr::copy_nonoverlapping(values.as_ptr(), info, 6); }
}

#[cfg(test)]
mod bridge_tests {
    use super::*;

    fn feed(engine: *mut Engine, block: usize) {
        let pcm: Vec<f32> = (0..1600).flat_map(|i| {
            let sample = ((block * 1600 + i) as f32 * std::f32::consts::TAU * 110.0 / 48000.0).sin() * 0.25;
            [sample, sample]
        }).collect();
        unsafe { ag_ingest(engine, pcm.as_ptr(), 1600, 48000.0); }
    }

    #[test]
    fn bridge_produces_finite_fft_and_stably_triggered_samples() {
        let engine = ag_create();
        let mut frequencies = vec![0.0; 8193];
        let mut levels = vec![0.0; 8193];
        let mut scope = vec![0.0; 48000];
        let mut secondary = vec![0.0; 8193];
        let mut scope2 = vec![0.0; 48000];
        let mut counts = FrameCounts { spectrum_count: 0, scope_count: 0, secondary_count: 0, scope2_count: 0 };
        for block in 0..20 {
            feed(engine, block);
            counts = unsafe { ag_process(engine, 0.0, frequencies.as_mut_ptr(), levels.as_mut_ptr(),
                secondary.as_mut_ptr(), 8193, scope.as_mut_ptr(), scope2.as_mut_ptr(), 48000) };
        }
        assert_eq!(counts.spectrum_count, 8193);
        assert!(counts.scope_count > 2 && counts.scope_count < 48000);
        assert_eq!((counts.secondary_count, counts.scope2_count), (0, 0));
        assert!(frequencies.iter().chain(&levels).all(|v| v.is_finite()));
        assert!(scope[..counts.scope_count as usize].iter().all(|v| v.is_finite()));
        let peak = levels.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).unwrap().0;
        assert!((frequencies[peak] - 110.0).abs() < 4.0,
            "peak at {} Hz, {} dB", frequencies[peak], levels[peak]);
        unsafe { ag_destroy(engine); }
    }

    #[test]
    fn all_meter_snapshots_follow_pcm_and_respect_capacities() {
        let engine = ag_create();
        for block in 0..120 { feed(engine, block); }
        let mut wave = vec![12345.0; 1024 * WAVE_STRIDE + 1];
        let mut stereo = vec![12345.0; 4001];
        let mut metrics = [12345.0; METRIC_COUNT + 1];
        let mut counts = [0, 0, 12345];
        unsafe { ag_read_meters(engine, wave.as_mut_ptr(), stereo.as_mut_ptr(), metrics.as_mut_ptr(), counts.as_mut_ptr()); }
        assert!((799..=800).contains(&counts[0]));
        assert!((1..=2000).contains(&counts[1]));
        assert!(metrics[..6].iter().all(|v| v.is_finite() && *v > -60.0 && *v < 0.0));
        assert!((metrics[6] - 1.0).abs() < 0.001);
        assert!(metrics[10..14].iter().all(|v| v.is_finite() && *v > -60.0 && *v < 0.0));
        assert!(wave[..counts[0] as usize * WAVE_STRIDE].chunks_exact(WAVE_STRIDE)
            .all(|v| v[0] <= v[1] && v[2] <= v[3] && v[4] == 0.0 && v[5] == 0.0));
        assert_eq!(wave[1024 * WAVE_STRIDE], 12345.0);
        assert_eq!(stereo[4000], 12345.0);
        assert_eq!(metrics[METRIC_COUNT], 12345.0);
        // Peak maxima restart after a read.
        unsafe { ag_read_meters(engine, wave.as_mut_ptr(), stereo.as_mut_ptr(), metrics.as_mut_ptr(), counts.as_mut_ptr()); }
        assert_eq!(&metrics[12..14], &[-120.0, -120.0]);
        assert_eq!(counts[2], 12345);
        unsafe { ag_destroy(engine); }
    }

    #[test]
    fn settings_select_side_and_rebuild_fft_without_changing_upstream() {
        let engine = ag_create();
        unsafe { ag_configure(engine, 1, 4096, 0, -90.0, 0, 100.0, -1.0); }
        for block in 0..20 { feed(engine, block); }
        let e = unsafe { &*engine };
        assert_eq!(e.frequencies.len(), 2049);
        assert!(e.levels.iter().all(|v| *v <= -89.0)); // mono has no Side
        assert_eq!(e.history.config().scroll_speed, 100.0);
        unsafe { ag_configure(engine, 2, 32768, 1, -120.0, 4, 400.0, 0.0); }
        for block in 20..60 { feed(engine, block); }
        let e = unsafe { &*engine };
        assert_eq!(e.frequencies.len(), 16385);
        assert!(e.levels.iter().any(|v| *v > -60.0));
        assert!(e.weighted);
        unsafe { ag_destroy(engine); }
    }

    #[test]
    fn invalid_pcm_is_ignored_and_sample_rate_changes_reconfigure_fft() {
        let engine = ag_create();
        let pcm = vec![0.0; 2048];
        unsafe { ag_ingest(engine, std::ptr::null(), 1024, 48000.0); }
        unsafe { ag_ingest(engine, pcm.as_ptr(), 1024, f32::NAN); }
        for rate in [44100.0, 96000.0] {
            for _ in 0..20 { unsafe { ag_ingest(engine, pcm.as_ptr(), 1024, rate); } }
            let e = unsafe { &*engine };
            assert!((e.frequencies.last().unwrap() - rate / 2.0).abs() < 1.0);
            assert!(e.levels.iter().all(|v| v.is_finite()));
        }
        unsafe { ag_destroy(engine); }
    }

    #[test]
    fn cursor_metadata_tracks_cycle_time_and_spectrogram_history() {
        let engine = ag_create();
        unsafe { ag_configure(engine, 0, 16384, 0, -120.0, 1, 200.0, 0.0); }
        for block in 0..40 { feed(engine, block); }
        let mut timing = [12345.0; 6];
        unsafe { ag_read_timing(engine, timing.as_mut_ptr()); }
        assert_eq!(timing[0], 48000.0);
        assert!((timing[1] - 1.0 / 110.0).abs() < 0.0002);
        assert!((timing[2] - 110.0).abs() < 2.0);
        assert!((timing[3] - 256.0 / 48000.0).abs() < 0.000001);
        assert!(timing[4] > 0.0 && timing[4] <= 512.0);
        assert_eq!(timing[5], 12345.0);
        // Silence must release pitch lock, rather than present a stale note.
        let silence = [0.0; 3200];
        for _ in 0..30 { unsafe { ag_ingest(engine, silence.as_ptr(), 1600, 48000.0); } }
        unsafe { ag_read_timing(engine, timing.as_mut_ptr()); }
        assert_eq!(timing[2], 0.0);
        unsafe { ag_destroy(engine); }
    }

    fn read_spectrogram(engine: *mut Engine) -> ([i64; 6], Vec<f32>) {
        let mut info = [0i64; 6];
        let needed = unsafe { ag_spectrogram_pending(engine, info.as_mut_ptr()) };
        let mut values = vec![0.0; needed as usize];
        unsafe { ag_spectrogram_read(engine, values.as_mut_ptr(), needed, info.as_mut_ptr()); }
        (info, values)
    }

    #[test]
    fn spectrogram_places_a_tone_on_its_row_and_reassignment_sharpens_it() {
        let rows = 400;
        let mut widths = Vec::new();
        for reassign in [0, 1] {
            let engine = ag_create();
            unsafe { ag_configure_spectrogram(engine, 4096, 16, 1, reassign, 1, 1, 300, rows, 1); }
            let pcm: Vec<f32> = (0..48000).flat_map(|i| {
                let sample = (i as f32 * std::f32::consts::TAU * 1000.0 / 48000.0).sin() * 0.5;
                [sample, sample]
            }).collect();
            for _ in 0..2 {
                for block in pcm.chunks(3200) { unsafe { ag_ingest(engine, block.as_ptr(), 1600, 48000.0); } }
            }
            let (info, values) = read_spectrogram(engine);
            assert_eq!(&info[..3], &[1, 300, rows as i64]);
            assert_eq!(info[4], 300);
            assert!(info[5] > 300);
            let newest = &values[values.len() - rows as usize..];
            let (peak, level) = newest.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).unwrap();
            let hz = FrequencyScale::Logarithmic.freq_at(1.0, 24000.0, (peak as f32 + 0.5) / rows as f32);
            assert!((hz - 1000.0).abs() < 25.0, "mode {reassign}: peak row at {hz} Hz");
            assert!(*level > -12.0 && *level < 0.0, "mode {reassign}: {level} dB");
            widths.push(newest.iter().filter(|v| **v > level - 30.0).count());
            // Further reads carry only the newly produced columns.
            for block in pcm.chunks(3200).take(2) { unsafe { ag_ingest(engine, block.as_ptr(), 1600, 48000.0); } }
            let (info, _) = read_spectrogram(engine);
            assert_eq!(info[0], 0);
            // Reassigned windows reach back at most one window (16 hops) plus one.
            assert!(info[4] >= 12 && info[4] <= 12 + 17, "{} columns", info[4]);
            // Changing analysis clears history.
            unsafe { ag_configure_spectrogram(engine, 8192, 16, 1, reassign, 1, 1, 300, rows, 1); }
            let (info, values) = read_spectrogram(engine);
            assert_eq!((info[0], info[4], values.len()), (1, 0, 0));
            unsafe { ag_destroy(engine); }
        }
        assert!(widths[1] < widths[0], "reassigned {} rows vs classic {} rows", widths[1], widths[0]);
    }

    #[test]
    fn options_add_secondary_traces_channels_rms_and_band_correlation() {
        let engine = ag_create();
        unsafe { ag_configure_options(engine, &MeterOptions { spectrum_secondary: 2, scope_channel: 3, scope_channel2: 2,
            scope_duration_ms: 20, waveform_channel1: 1, waveform_channel2: 2, waveform_rms: 1, stereo_bands: 1,
            ..MeterOptions::default() }); }
        for block in 0..120 { feed(engine, block); }
        let e = unsafe { &*engine };
        // feed() is mono: Side is silent in the secondary spectrum and second scope trace.
        assert_eq!(e.secondary_levels.len(), e.levels.len());
        assert!(e.secondary_levels.iter().all(|v| *v <= -100.0));
        assert!(!e.waveform2.is_empty() && e.waveform2.iter().all(|v| v.abs() < 1e-6));
        assert!(e.waveform.iter().any(|v| v.abs() > 0.2));
        let newest = e.history_columns.back().unwrap();
        // Mid of a 0.25 sine: RMS ≈ 0.177; Side is silent.
        assert!(newest[1] > 0.2 && (newest[4] - 0.177).abs() < 0.03, "{newest:?}");
        assert_eq!((newest[2], newest[3], newest[5]), (0.0, 0.0, 0.0));
        assert!(e.metrics[6..10].iter().all(|v| (v - 1.0).abs() < 0.01), "{:?}", &e.metrics[6..10]);
        unsafe { ag_destroy(engine); }
    }

    #[test]
    fn bridge_respects_small_output_capacities() {
        let engine = ag_create();
        let mut frequencies = [12345.0; 8];
        let mut levels = [12345.0; 8];
        let mut scope = [12345.0; 8];
        let mut secondary = [12345.0; 8];
        let mut scope2 = [12345.0; 8];
        unsafe { ag_configure_options(engine, &MeterOptions { spectrum_secondary: 2, scope_channel2: 3, ..MeterOptions::default() }); }
        for block in 0..20 {
            feed(engine, block);
            let counts = unsafe { ag_process(engine, 0.65, frequencies.as_mut_ptr(), levels.as_mut_ptr(),
                secondary.as_mut_ptr(), 5, scope.as_mut_ptr(), scope2.as_mut_ptr(), 5) };
            assert!(counts.spectrum_count <= 5 && counts.scope_count <= 5);
        }
        assert_eq!(&frequencies[5..], &[12345.0; 3]);
        assert_eq!(&levels[5..], &[12345.0; 3]);
        assert_eq!(&scope[5..], &[12345.0; 3]);
        assert_eq!(&secondary[5..], &[12345.0; 3]);
        assert_eq!(&scope2[5..], &[12345.0; 3]);
        unsafe { ag_destroy(engine); }
    }
}
