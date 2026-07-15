// snddma_coreaudio.m — native iOS audio backend for the engine's DMA sound mixer.
// Implements snddma_driver_t with a RemoteIO AudioUnit (low latency) whose render
// callback pulls S16 interleaved stereo from the mixer's ring buffer (dma.buffer),
// exactly like upstream's SDL Filler. No SDL, no dlopen — fits the native port (D4).
// M7. Registered in dma.c s_drivers[] via an overlay; enabled by USE_SNDDMA=1.
#import <AVFoundation/AVFoundation.h>
#import <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/zone.h"
#include "client/sound/dma.h"

static AudioUnit s_au;
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static bool s_running;

// Real-time render callback: copy len bytes from the mixer ring buffer to the device.
// Mirrors src/unix/sound/sdl.c Filler (S16 stereo, dma.samplepos in samples).
static OSStatus ca_render(void *ref, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                          AudioBufferList *io)
{
    (void)ref; (void)flags; (void)ts; (void)bus; (void)frames;
    uint8_t *stream = (uint8_t *)io->mBuffers[0].mData;
    int len = (int)io->mBuffers[0].mDataByteSize;

    pthread_mutex_lock(&s_lock);
    if (!dma.buffer) { memset(stream, 0, len); pthread_mutex_unlock(&s_lock); return noErr; }
    int size = dma.samples << 1;            // bytes in the ring (samples * 2 for S16)
    int pos  = dma.samplepos << 1;
    int wrapped = pos + len - size;
    if (wrapped < 0) {
        memcpy(stream, dma.buffer + pos, len);
        dma.samplepos += len >> 1;
    } else {
        int remaining = size - pos;
        memcpy(stream, dma.buffer + pos, remaining);
        memcpy(stream + remaining, dma.buffer, wrapped);
        dma.samplepos = wrapped >> 1;
    }
    pthread_mutex_unlock(&s_lock);
    return noErr;
}

static void ca_shutdown(void)
{
    if (s_au) {
        AudioOutputUnitStop(s_au);
        AudioUnitUninitialize(s_au);
        AudioComponentInstanceDispose(s_au);
        s_au = NULL;
    }
    s_running = false;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:0 error:nil];
    Z_Freep(&dma.buffer);
}

static sndinitstat_t ca_init(void)
{
    int freq = s_khz->integer >= 48 ? 48000 : s_khz->integer >= 44 ? 44100 :
               s_khz->integer >= 22 ? 22050 : 11025;

    // Audio session: Playback = game sound plays through the silent switch (game
    // convention; also makes a device sound-test valid regardless of the mute switch).
    NSError *err = nil;
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:AVAudioSessionCategoryPlayback error:&err];
    [sess setActive:YES error:&err];
    if (err) Com_WPrintf("CoreAudio: session warning: %s\n", err.localizedDescription.UTF8String);

    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &s_au) != noErr) {
        Com_EPrintf("CoreAudio: no RemoteIO unit\n"); return SIS_FAILURE;
    }

    AudioStreamBasicDescription fmt = {
        .mSampleRate = freq,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBitsPerChannel = 16,
        .mChannelsPerFrame = 2,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4,          // 2 ch * 16-bit
        .mBytesPerPacket = 4,
    };
    if (AudioUnitSetProperty(s_au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                             0, &fmt, sizeof fmt) != noErr) {
        Com_EPrintf("CoreAudio: stream format rejected\n"); ca_shutdown(); return SIS_FAILURE;
    }
    AURenderCallbackStruct cb = { .inputProc = ca_render };
    AudioUnitSetProperty(s_au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);

    if (AudioUnitInitialize(s_au) != noErr) { Com_EPrintf("CoreAudio: init failed\n"); ca_shutdown(); return SIS_FAILURE; }

    // Mixer ring buffer, mirroring the SDL driver's setup.
    dma.speed = freq;
    dma.channels = 2;
    dma.samples = 0x8000 * 2;
    dma.submission_chunk = 1;
    dma.samplebits = 16;
    dma.samplepos = 0;
    dma.buffer = Z_Mallocz(dma.samples * 2);

    if (AudioOutputUnitStart(s_au) != noErr) { Com_EPrintf("CoreAudio: start failed\n"); ca_shutdown(); return SIS_FAILURE; }
    s_running = true;
    Com_Printf("Using CoreAudio (RemoteIO) at %d Hz.\n", freq);
    return SIS_SUCCESS;
}

// Mixer critical section: the render callback runs on a real-time thread, so guard
// dma.buffer with the same lock while the mixer paints into it.
static void ca_begin_painting(void) { pthread_mutex_lock(&s_lock); }
static void ca_submit(void)         { pthread_mutex_unlock(&s_lock); }

static void ca_activate(bool active)
{
    if (!s_au) return;
    if (active && !s_running)      { [[AVAudioSession sharedInstance] setActive:YES error:nil]; AudioOutputUnitStart(s_au); s_running = true; }
    else if (!active && s_running) { AudioOutputUnitStop(s_au); s_running = false; }
}

const snddma_driver_t snddma_coreaudio = {
    .name = "coreaudio",
    .init = ca_init,
    .shutdown = ca_shutdown,
    .begin_painting = ca_begin_painting,
    .submit = ca_submit,
    .activate = ca_activate,
};
