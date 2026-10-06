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
// image 512*192 bytes, counts 2 int32s. Caller serializes with ingestion.
void ag_read_meters(void *engine, float *wave, float *stereo, float *metrics,
    uint8_t *image, int32_t *counts);
// Required capacity: 5 floats; sample rate, scope seconds, cycle Hz, spectrogram hop seconds, column count.
void ag_read_timing(void *engine, float *timing);
#endif
