#ifndef AUDIOGLASS_DSP_H
#define AUDIOGLASS_DSP_H
#include <stdint.h>
#include <CoreAudio/CoreAudio.h>
typedef struct { int32_t spectrum_count; int32_t scope_count; } AGFrameCounts;
void *ag_create(void);
void ag_destroy(void *engine);
void ag_configure(void *engine, int32_t channel, int32_t fft_size, int32_t weighted,
    float floor_db, int32_t trigger_cycles, float wave_speed, float smoothing);
void ag_ingest(void *engine, const float *pcm, int32_t frames, float sample_rate);
// Single producer (HAL callback), single consumer (analysis queue).
typedef struct AGTransport AGTransport;
AGTransport *ag_transport_create(void);
void ag_transport_destroy(AGTransport *transport);
OSStatus ag_transport_start(AGTransport *transport, AudioDeviceID device);
OSStatus ag_transport_stop(AGTransport *transport);
uint32_t ag_transport_read(AGTransport *transport, float *stereo, uint32_t capacity);
uint64_t ag_transport_dropped(AGTransport *transport);
uint64_t ag_transport_received(AGTransport *transport);
void ag_transport_push(AGTransport *transport, const AudioBufferList *buffers);
AGFrameCounts ag_process(void *engine, float smoothing,
    float *frequencies, float *levels, int32_t spectrum_capacity,
    float *waveform, int32_t scope_capacity);
// Required capacities: wave 4096 floats, stereo 4000 floats, metrics 7 floats,
// counts 2 int32s. Caller serializes with ingestion.
void ag_read_meters(void *engine, float *wave, float *stereo, float *metrics, int32_t *counts);
// Spectrogram: analysis changes clear history; geometry changes re-render it.
// columns = time extent in points, rows = frequency extent in pixels.
void ag_configure_spectrogram(void *engine, int32_t fft_size, int32_t hop_divisor, int32_t window,
    int32_t reassign, int32_t zero_padding, int32_t scale, int32_t columns, int32_t rows, int32_t row_span);
// info (6): reset, ring columns, rows, first column, column count, columns shown.
// Returns the float capacity the next read needs.
int64_t ag_spectrogram_pending(void *engine, int64_t *info);
// Writes pending columns oldest first: rows dB values each, lowest frequency
// first, -1000 when empty. Writes nothing when capacity is too small.
void ag_spectrogram_read(void *engine, float *values, int64_t capacity, int64_t *info);
// Required capacity: 5 floats; sample rate, scope seconds, cycle Hz, spectrogram hop seconds, column count.
void ag_read_timing(void *engine, float *timing);
#endif
