// SPDX-License-Identifier: GPL-3.0-or-later
//! Audioglass CPU rasterizer for upstream spectrogram columns.
//!
//! Mirrors upstream's GPU rules (render.rs / spectrogram.wgsl): reassigned
//! points are splatted one display point wide at their time-offset column and
//! accumulate linear power per pixel; classic columns are sampled per pixel row.
//! Rows are physical pixels; columns are one display point (one hop) each.
//! Only changed columns are handed to the app, which keeps a GPU ring texture.

use std::collections::VecDeque;

use crate::util::audio::{DB_FLOOR, FrequencyScale};
use crate::visuals::spectrogram::processor::{SpectrogramColumn, SpectrogramPoint, SpectrogramUpdate};

pub const MAX_COLUMNS: usize = 4096;
pub const MAX_ROWS: usize = 2048;
/// Written for pixels with no energy above the analysis floor.
pub const EMPTY_DB: f32 = -1000.0;
// Largest reassigned offset is half the window: 128 / 2 hops at the finest hop.
const FUTURE_COLUMNS: usize = 65;
const RETAINED_BYTE_BUDGET: usize = 64 * 1024 * 1024;
// Keep in sync with processor.rs CLASSIC_DB_STORE_*.
const CLASSIC_DB_LO: f32 = -144.0;
const CLASSIC_DB_RANGE: f32 = 156.0;
// Upstream display axis starts at 1 Hz, independent of bin spacing.
const DISPLAY_MIN_HZ: f32 = 1.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Geometry {
    /// Visible time extent in display points.
    pub columns: usize,
    /// Frequency extent in physical pixels.
    pub rows: usize,
    /// Physical pixels per display point (a splat covers this many rows).
    pub row_span: usize,
    pub scale: FrequencyScale,
}

impl Geometry {
    fn normalized(self) -> Self {
        Self {
            columns: self.columns.clamp(1, MAX_COLUMNS),
            rows: self.rows.clamp(1, MAX_ROWS),
            row_span: self.row_span.clamp(1, 4),
            scale: self.scale,
        }
    }
}

impl Default for Geometry {
    fn default() -> Self {
        Self { columns: 512, rows: 192, row_span: 1, scale: FrequencyScale::Logarithmic }
    }
}

/// Columns the app must apply before drawing.
#[derive(Debug, PartialEq)]
pub struct Pending {
    /// Discard every existing column and resize to `columns` x `rows`.
    pub reset: bool,
    pub columns: usize,
    pub rows: usize,
    /// Absolute index of the first column carried.
    pub first: u64,
    pub count: usize,
    /// Columns shown since the last reset; newest is `produced - 1`.
    pub produced: u64,
}

pub struct SpectrogramRaster {
    geometry: Geometry,
    sample_rate: f32,
    power_scale: f32,
    reassigned: bool,
    retained: VecDeque<SpectrogramColumn>,
    retained_bytes: usize,
    produced: u64,
    /// Newest columns withheld while later windows still fill them.
    lag: u64,
    /// Linear power per pixel, `(columns + FUTURE_COLUMNS) x rows`; 0 is empty.
    ring: Vec<f32>,
    /// Slots for absolute columns below this have been cleared for use.
    cleared_through: u64,
    /// Columns below this hold nothing (after a reset or a partial replay).
    valid_from: u64,
    dirty_from: Option<u64>,
    full: bool,
    row_edges: Vec<f32>,
}

impl Default for SpectrogramRaster {
    fn default() -> Self {
        let mut raster = Self {
            geometry: Geometry::default(),
            sample_rate: 48_000.0,
            power_scale: 1.0,
            reassigned: false,
            retained: VecDeque::new(),
            retained_bytes: 0,
            produced: 0,
            lag: 0,
            ring: Vec::new(),
            cleared_through: 0,
            valid_from: 0,
            dirty_from: None,
            full: true,
            row_edges: Vec::new(),
        };
        raster.rebuild();
        raster
    }
}

fn column_bytes(column: &SpectrogramColumn) -> usize {
    match column {
        SpectrogramColumn::Reassigned(points) => points.len() * size_of::<SpectrogramPoint>(),
        SpectrogramColumn::Classic(levels) => levels.len() * size_of::<u16>(),
    }
}

fn unpack_db(packed: u16) -> f32 {
    f32::from(packed) / 65535.0 * CLASSIC_DB_RANGE + CLASSIC_DB_LO
}

impl SpectrogramRaster {
    pub fn geometry(&self) -> Geometry {
        self.geometry
    }

    pub fn produced(&self) -> u64 {
        self.produced
    }

    /// Columns presented to the app; newest is `shown() - 1`.
    pub fn shown(&self) -> u64 {
        self.produced.saturating_sub(self.lag)
    }

    pub fn populated(&self) -> usize {
        self.shown().saturating_sub(self.valid_from).min(self.geometry.columns as u64) as usize
    }

    /// Reassigned points are centred half a window (in hops) before their
    /// column; withholding that many columns keeps the newest edge complete.
    pub fn set_lag(&mut self, columns: usize) {
        self.lag = columns as u64;
        self.full = true;
    }

    fn slots(&self) -> usize {
        self.geometry.columns + FUTURE_COLUMNS
    }

    fn min_hz(&self) -> f32 {
        DISPLAY_MIN_HZ.min(self.sample_rate * 0.25)
    }

    fn max_hz(&self) -> f32 {
        (self.sample_rate * 0.5).max(1.0)
    }

    /// Changes take effect immediately, re-rendering retained history.
    pub fn set_geometry(&mut self, geometry: Geometry) {
        let geometry = geometry.normalized();
        if geometry != self.geometry {
            self.geometry = geometry;
            self.rebuild();
        }
    }

    /// Drops all history, e.g. after an analysis configuration change.
    pub fn clear(&mut self) {
        self.retained.clear();
        self.retained_bytes = 0;
        self.produced = 0;
        self.rebuild();
    }

    pub fn push(&mut self, update: SpectrogramUpdate) {
        let rate_changed = update.sample_rate != self.sample_rate;
        self.sample_rate = update.sample_rate;
        self.power_scale = update.reassigned_power_scale;
        if update.reset || rate_changed {
            self.clear();
        }
        for column in update.new_columns {
            let reassigned = matches!(column, SpectrogramColumn::Reassigned(_));
            if reassigned != self.reassigned {
                self.reassigned = reassigned;
                self.clear();
            }
            let index = self.produced;
            self.rasterize(index, &column);
            self.produced += 1;
            self.dirty_from = Some(self.dirty_from.map_or(index, |dirty| dirty.min(index)));
            self.retained_bytes += column_bytes(&column);
            self.retained.push_back(column);
            while self.retained.len() > MAX_COLUMNS + FUTURE_COLUMNS
                || (self.retained_bytes > RETAINED_BYTE_BUDGET && self.retained.len() > 1)
            {
                if let Some(old) = self.retained.pop_front() {
                    self.retained_bytes -= column_bytes(&old);
                }
            }
        }
    }

    /// Re-renders retained columns into a freshly sized ring.
    fn rebuild(&mut self) {
        let Geometry { rows, scale, .. } = self.geometry;
        let (lo, hi) = (self.min_hz(), self.max_hz());
        self.row_edges = (0..=rows).map(|row| scale.freq_at(lo, hi, row as f32 / rows as f32)).collect();
        self.ring.clear();
        self.ring.resize(self.slots() * rows, 0.0);
        self.full = true;
        self.dirty_from = None;
        // Older columns can still reach visible ones through positive offsets.
        let replay = self.retained.len().min(self.geometry.columns + FUTURE_COLUMNS);
        let first = self.produced - replay as u64;
        self.valid_from = first;
        self.cleared_through = first;
        let skip = self.retained.len() - replay;
        let columns: Vec<SpectrogramColumn> = self.retained.drain(..).collect();
        for (offset, column) in columns.iter().skip(skip).enumerate() {
            self.rasterize(first + offset as u64, column);
        }
        self.retained = columns.into();
    }

    fn ensure_slot(&mut self, column: u64) {
        let rows = self.geometry.rows;
        let slots = self.slots() as u64;
        while self.cleared_through <= column {
            let slot = (self.cleared_through % slots) as usize;
            self.ring[slot * rows..(slot + 1) * rows].fill(0.0);
            self.cleared_through += 1;
        }
    }

    fn rasterize(&mut self, index: u64, column: &SpectrogramColumn) {
        self.ensure_slot(index);
        match column {
            SpectrogramColumn::Classic(levels) => self.rasterize_classic(index, levels),
            SpectrogramColumn::Reassigned(points) => self.rasterize_reassigned(index, points),
        }
    }

    fn rasterize_classic(&mut self, index: u64, levels: &[u16]) {
        let rows = self.geometry.rows;
        let slot = (index % self.slots() as u64) as usize;
        let Some(max_bin) = levels.len().checked_sub(1).filter(|bin| *bin > 0) else { return };
        let bin_hz = self.max_hz() / max_bin as f32;
        for row in 0..rows {
            let (low, high) = (self.row_edges[row], self.row_edges[row + 1]);
            let first = (low / bin_hz).ceil() as usize;
            let last = ((high / bin_hz).ceil() as usize).saturating_sub(1).min(max_bin);
            // Upstream samples the row centre; when a row spans several bins,
            // keep their peak so narrow lines are not skipped at high frequencies.
            let db = if last > first {
                levels[first..=last].iter().map(|&packed| unpack_db(packed)).fold(f32::MIN, f32::max)
            } else {
                let bin = 0.5 * (low + high) / bin_hz;
                if bin > max_bin as f32 { continue; }
                let below = bin.floor() as usize;
                let above = (below + 1).min(max_bin);
                let t = bin - below as f32;
                unpack_db(levels[below]) * (1.0 - t) + unpack_db(levels[above]) * t
            };
            // Floor bins stay transparent, like upstream's classic shader.
            self.ring[slot * rows + row] = if db > DB_FLOOR + 0.01 { 10f32.powf(db / 10.0) } else { 0.0 };
        }
    }

    fn rasterize_reassigned(&mut self, index: u64, points: &[SpectrogramPoint]) {
        let Geometry { columns, rows, row_span, scale } = self.geometry;
        let slots = self.slots() as u64;
        let (lo, hi) = (self.min_hz(), self.max_hz());
        let oldest = self.valid_from.max((index + 1).saturating_sub(columns as u64));
        let newest = index + FUTURE_COLUMNS as u64 - 1;
        let half_span = row_span as f32 * 0.5;
        let support = self.lag as f32;
        for point in points {
            if !(point.power > 0.0) { continue; }
            // Audioglass deviation: estimates outside the window's support come
            // from near-silent bins and would scatter speckles across history.
            if self.lag > 0 && (point.time_offset + support).abs() > support + 1.0 { continue; }
            let norm = scale.pos_of(lo, hi, point.freq_hz);
            if !(-0.01..=1.01).contains(&norm) { continue; }
            let target = index as i64 + (point.time_offset + 0.5).floor() as i64;
            if target < oldest as i64 || target > newest as i64 { continue; }
            let target = target as u64;
            self.ensure_slot(target);
            if target < index {
                self.dirty_from = Some(self.dirty_from.map_or(target, |dirty| dirty.min(target)));
            }
            // A one-point square covers the pixel rows whose centres it contains.
            let y = norm * rows as f32;
            let first = (y - half_span - 0.5).floor() as i64 + 1;
            let base = (target % slots) as usize * rows;
            for row in first.max(0)..(first + row_span as i64).min(rows as i64) {
                self.ring[base + row as usize] += point.power;
            }
        }
    }

    /// Describes the columns `read` will write; does not consume them.
    pub fn pending(&self) -> Pending {
        let columns = self.geometry.columns;
        let shown = self.shown();
        let visible = shown.saturating_sub(columns as u64);
        let first = if self.full { visible } else { self.dirty_from.unwrap_or(shown).clamp(visible, shown) };
        Pending {
            reset: self.full,
            columns,
            rows: self.geometry.rows,
            first,
            count: (shown - first) as usize,
            produced: shown,
        }
    }

    /// Writes pending columns oldest first as dB (`EMPTY_DB` when silent),
    /// `rows` values per column with row 0 at the lowest frequency.
    pub fn read(&mut self, output: &mut [f32]) -> Pending {
        let pending = self.pending();
        let rows = self.geometry.rows;
        if output.len() < pending.count * rows { return Pending { count: 0, ..pending }; }
        let slots = self.slots() as u64;
        let scale = if self.reassigned { self.power_scale } else { 1.0 };
        for offset in 0..pending.count {
            let index = pending.first + offset as u64;
            let out = &mut output[offset * rows..(offset + 1) * rows];
            if index < self.valid_from {
                out.fill(EMPTY_DB);
                continue;
            }
            let base = (index % slots) as usize * rows;
            for (value, &power) in out.iter_mut().zip(&self.ring[base..base + rows]) {
                *value = if power > 0.0 { (10.0 * (power * scale).log10()).max(DB_FLOOR) } else { EMPTY_DB };
            }
        }
        self.full = false;
        // Withheld columns are delivered once they are shown.
        self.dirty_from = (self.produced > pending.produced).then_some(pending.produced);
        pending
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn update(columns: Vec<SpectrogramColumn>, reset: bool) -> SpectrogramUpdate {
        SpectrogramUpdate {
            fft_size: 4096, hop_size: 256, sample_rate: 48_000.0, history_length: 0,
            reset, reassigned_power_scale: 1.0, new_columns: columns,
        }
    }

    fn point(time_offset: f32, freq_hz: f32, power: f32) -> SpectrogramPoint {
        SpectrogramPoint { time_offset, freq_hz, power }
    }

    fn geometry(columns: usize, rows: usize, row_span: usize) -> Geometry {
        Geometry { columns, rows, row_span, scale: FrequencyScale::Linear }
    }

    fn read_all(raster: &mut SpectrogramRaster) -> (Pending, Vec<f32>) {
        let pending = raster.pending();
        let mut values = vec![0.0; pending.count * pending.rows];
        (raster.read(&mut values), values)
    }

    #[test]
    fn reassigned_points_accumulate_power_in_their_offset_column_and_row() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(8, 24, 1));
        // 24 linear rows over 0–24 kHz: 12.5 kHz lands in row 12.
        raster.push(update(vec![
            SpectrogramColumn::Reassigned(vec![]),
            SpectrogramColumn::Reassigned(vec![point(0.0, 12_500.0, 1e-3), point(0.2, 12_600.0, 1e-3), point(-0.7, 12_500.0, 1e-2)]),
        ], true));
        let (pending, values) = read_all(&mut raster);
        assert!(pending.reset);
        assert_eq!((pending.first, pending.count, pending.produced), (0, 2, 2));
        // Two equal points sum (+3 dB); the -0.7 offset moves into column 0.
        assert!((values[24 + 12] - 10.0 * 2e-3f32.log10()).abs() < 1e-4);
        assert!((values[12] - -20.0).abs() < 1e-4);
        assert!(values.iter().enumerate().all(|(i, v)| i == 12 || i == 36 || *v == EMPTY_DB));
    }

    #[test]
    fn later_columns_mark_earlier_columns_dirty_and_future_offsets_wait() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(8, 24, 1));
        raster.push(update((0..3).map(|_| SpectrogramColumn::Reassigned(vec![])).collect(), true));
        read_all(&mut raster);
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![
            point(-2.0, 1_500.0, 1.0), point(1.0, 1_500.0, 1.0),
        ])], false));
        let (pending, values) = read_all(&mut raster);
        assert!(!pending.reset);
        assert_eq!((pending.first, pending.count), (1, 3));
        assert_eq!(values[1], 0.0);
        assert!(values[24..].iter().all(|v| *v == EMPTY_DB));
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![])], false));
        let (pending, values) = read_all(&mut raster);
        assert_eq!((pending.first, pending.count), (4, 1));
        assert_eq!(values[1], 0.0);
    }

    #[test]
    fn retina_splats_cover_the_rows_inside_one_display_point() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(4, 48, 2));
        // 12.5 kHz -> y = 25.0 physical rows; a 2-row square covers rows 24 and 25.
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![point(0.0, 12_500.0, 1.0)])], true));
        let (_, values) = read_all(&mut raster);
        let lit: Vec<usize> = values.iter().enumerate().filter(|(_, v)| **v > EMPTY_DB).map(|(i, _)| i).collect();
        assert_eq!(lit, vec![24, 25]);
    }

    #[test]
    fn classic_rows_interpolate_bins_or_keep_the_peak_of_several() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(4, 4, 1));
        let floor = ((DB_FLOOR - CLASSIC_DB_LO) / CLASSIC_DB_RANGE * 65535.0).round() as u16;
        let mut levels = vec![floor; 2049];
        let loud = ((-6.0 - CLASSIC_DB_LO) / CLASSIC_DB_RANGE * 65535.0).round() as u16;
        levels[1600] = loud; // 18.75 kHz: one narrow line among the top row's bins
        raster.push(update(vec![SpectrogramColumn::Classic(levels)], true));
        let (_, values) = read_all(&mut raster);
        assert!((values[3] - -6.0).abs() < 0.01);
        assert_eq!(&values[..3], &[EMPTY_DB; 3]);
    }

    #[test]
    fn resizing_re_renders_retained_history_and_resets_the_app_copy() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(4, 24, 1));
        let columns = (0..10).map(|_| SpectrogramColumn::Reassigned(vec![point(0.0, 6_500.0, 1.0)])).collect();
        raster.push(update(columns, true));
        read_all(&mut raster);
        raster.set_geometry(geometry(8, 48, 1));
        let (pending, values) = read_all(&mut raster);
        assert!(pending.reset);
        assert_eq!((pending.columns, pending.rows, pending.first, pending.count), (8, 48, 2, 8));
        // 6.5 kHz is y = 12.998 of 48 rows; every replayed column keeps its point.
        assert!(values.chunks(48).all(|column| column[12] == 0.0));
        assert_eq!(raster.populated(), 8);
    }

    #[test]
    fn lagged_columns_are_withheld_until_complete() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(8, 24, 1));
        raster.set_lag(2);
        raster.push(update((0..3).map(|_| SpectrogramColumn::Reassigned(vec![])).collect(), true));
        let (pending, _) = read_all(&mut raster);
        assert_eq!((pending.first, pending.count, pending.produced), (0, 1, 1));
        // A later window completes column 1 and touches withheld column 2.
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![
            point(-2.0, 1_500.0, 1.0), point(-1.0, 1_500.0, 1.0),
        ])], false));
        let (pending, values) = read_all(&mut raster);
        assert_eq!((pending.first, pending.count, pending.produced), (1, 1, 2));
        assert_eq!(values[1], 0.0);
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![])], false));
        let (pending, values) = read_all(&mut raster);
        assert_eq!((pending.first, pending.count), (2, 1));
        assert_eq!(values[1], 0.0);
        assert_eq!(raster.populated(), 3);
        // Estimates beyond the window support (here ±2 around -2) are dropped.
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![point(-6.0, 1_500.0, 1.0)])], false));
        let (pending, values) = read_all(&mut raster);
        assert_eq!((pending.first, pending.count), (3, 1));
        assert!(values.iter().all(|v| *v == EMPTY_DB));
    }

    #[test]
    fn analysis_reset_and_small_output_do_not_present_stale_columns() {
        let mut raster = SpectrogramRaster::default();
        raster.set_geometry(geometry(4, 8, 1));
        raster.push(update((0..4).map(|_| SpectrogramColumn::Reassigned(vec![point(0.0, 100.0, 1.0)])).collect(), true));
        let mut tiny = [7.0; 3];
        assert_eq!(raster.read(&mut tiny).count, 0);
        assert_eq!(tiny, [7.0; 3]);
        raster.push(update(vec![SpectrogramColumn::Reassigned(vec![])], true));
        let (pending, values) = read_all(&mut raster);
        assert!(pending.reset);
        assert_eq!((pending.first, pending.count, raster.populated()), (0, 1, 1));
        assert!(values.iter().all(|v| *v == EMPTY_DB));
    }
}
