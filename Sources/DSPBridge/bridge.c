#include "DSPBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

#define AG_RING_FRAMES 65536u
struct AGTransport {
    float pcm[AG_RING_FRAMES * 2];
    _Atomic uint64_t written, read, dropped, received;
    AudioDeviceID device;
    AudioDeviceIOProcID io;
};
AGTransport *ag_transport_create(void) { return calloc(1, sizeof(AGTransport)); }

// HAL's float32 PCM is copied into a bounded stereo ring. No allocation, locks,
// Objective-C, dispatch, logging, or DSP is permitted on this path.
void ag_transport_push(AGTransport *t, const AudioBufferList *abl) {
    if (!t || !abl || !abl->mNumberBuffers) return;
    const float *channels[2] = {0};
    uint32_t strides[2] = {0}, count = 0, frames = UINT32_MAX;
    for (uint32_t b = 0; b < abl->mNumberBuffers && count < 2; ++b) {
        const AudioBuffer *buffer = &abl->mBuffers[b];
        if (!buffer->mData || !buffer->mNumberChannels) return;
        uint32_t n = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (n < frames) frames = n;
        for (uint32_t c = 0; c < buffer->mNumberChannels && count < 2; ++c) {
            channels[count] = (const float *)buffer->mData + c;
            strides[count++] = buffer->mNumberChannels;
        }
    }
    if (!count || !frames || frames == UINT32_MAX) return;
    if (count == 1) { channels[1] = channels[0]; strides[1] = strides[0]; }
    uint64_t w = atomic_load_explicit(&t->written, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&t->read, memory_order_acquire);
    atomic_fetch_add_explicit(&t->received, frames, memory_order_relaxed);
    if (frames > AG_RING_FRAMES - (w - r)) {
        atomic_fetch_add_explicit(&t->dropped, frames, memory_order_relaxed);
        return;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        uint32_t index = ((w + i) % AG_RING_FRAMES) * 2;
        for (uint32_t c = 0; c < 2; ++c) {
            float sample = channels[c][i * strides[c]];
            t->pcm[index + c] = isfinite(sample) ? sample : 0;
        }
    }
    atomic_store_explicit(&t->written, w + frames, memory_order_release);
}
static OSStatus capture(AudioDeviceID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    ag_transport_push(context, input);
    return noErr;
}
OSStatus ag_transport_start(AGTransport *t, AudioDeviceID device) {
    if (!t || t->io) return kAudioHardwareIllegalOperationError;
    t->device = device;
    OSStatus status = AudioDeviceCreateIOProcID(device, capture, t, &t->io);
    if (status == noErr) status = AudioDeviceStart(device, t->io);
    if (status != noErr && t->io) { AudioDeviceDestroyIOProcID(device, t->io); t->io = NULL; }
    return status;
}
OSStatus ag_transport_stop(AGTransport *t) {
    if (!t || !t->io) return noErr;
    OSStatus status = AudioDeviceStop(t->device, t->io);
    OSStatus destroyed = AudioDeviceDestroyIOProcID(t->device, t->io);
    if (destroyed == noErr) t->io = NULL;
    return status != noErr ? status : destroyed;
}
void ag_transport_destroy(AGTransport *t) {
    if (!t) return;
    ag_transport_stop(t);
    // If HAL could not detach the callback, retain storage rather than free a
    // potentially active real-time context. Normal shutdown frees it here.
    if (!t->io) free(t);
}
uint32_t ag_transport_read(AGTransport *t, float *stereo, uint32_t capacity) {
    uint64_t r = atomic_load_explicit(&t->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&t->written, memory_order_acquire);
    uint32_t n = (uint32_t)(w - r);
    if (n > capacity) n = capacity;
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t index = ((r + i) % AG_RING_FRAMES) * 2;
        stereo[i * 2] = t->pcm[index]; stereo[i * 2 + 1] = t->pcm[index + 1];
    }
    atomic_store_explicit(&t->read, r + n, memory_order_release);
    return n;
}
uint64_t ag_transport_dropped(AGTransport *t) { return atomic_load(&t->dropped); }
uint64_t ag_transport_received(AGTransport *t) { return atomic_load(&t->received); }
