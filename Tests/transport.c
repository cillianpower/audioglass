#include "DSPBridge.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <pthread.h>
#include <sched.h>

static AGTransport *ring;
static void *producer(void *unused) {
    float samples[256 * 2];
    AudioBufferList abl = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(samples), samples}}};
    for (int block = 0; block < 10000; ++block) {
        for (int i = 0; i < 256; ++i) {
            samples[i * 2] = (float)(block * 256 + i);
            samples[i * 2 + 1] = -samples[i * 2];
        }
        ag_transport_push(ring, &abl);
        sched_yield();
    }
    return NULL;
}
int main(void) {
    ring = ag_transport_create();
    float mono[] = {1, NAN, 3}, output[32];
    AudioBufferList abl = {.mNumberBuffers = 1, .mBuffers = {{1, sizeof(mono), mono}}};
    ag_transport_push(ring, &abl);
    assert(ag_transport_read(ring, output, 2) == 2);
    assert(output[0] == 1 && output[1] == 1 && output[2] == 0 && output[3] == 0);
    assert(ag_transport_read(ring, output, 16) == 1 && output[0] == 3);
    ag_transport_destroy(ring);
    ring = ag_transport_create();
    struct { UInt32 count; AudioBuffer buffers[2]; } planar = {2, {{1, 12, mono}, {1, 12, mono}}};
    ag_transport_push(ring, (AudioBufferList *)&planar);
    assert(ag_transport_read(ring, output, 16) == 3 && output[4] == 3 && output[5] == 3);
    ag_transport_destroy(ring);
    ring = ag_transport_create();
    pthread_t thread;
    pthread_create(&thread, NULL, producer, NULL);
    float previous = -1;
    // Read while the producer runs: drops may skip whole blocks but samples
    // must remain ordered, paired, and uncorrupted across wraparound.
    while (ag_transport_received(ring) < 2560000) {
        uint32_t count = ag_transport_read(ring, output, 16);
        for (unsigned i = 0; i < count; ++i) {
            assert(output[i * 2] > previous);
            assert(output[i * 2 + 1] == -output[i * 2]);
            previous = output[i * 2];
        }
    }
    pthread_join(thread, NULL);
    while (ag_transport_read(ring, output, 16)) {}
    assert(ag_transport_dropped(ring) % 256 == 0);
    ag_transport_destroy(ring);
    puts("transport: mono, planar, finite samples, overflow and concurrent wraparound passed");
}
