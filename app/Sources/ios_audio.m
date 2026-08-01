/*
 * ios_audio.m — AVAudioSession policy + the engine's master mix gain.
 *
 * Two knobs, both surfaced in the iOS Settings "Audio" section:
 *
 *   ios_audio_mode  what happens when another app is already playing (Music, a
 *                   podcast, …). Three of the five modes are pure session
 *                   category/option choices that iOS enforces for us; the other
 *                   two ("lower/mute game audio") need the engine to attenuate
 *                   its OWN mix, because iOS will duck other apps for you but
 *                   never ducks you. Overlay patch 0021 exposes that as
 *                   S_SetExternalGain().
 *   ios_volume      a plain master volume, multiplied into the same gain. It
 *                   sits ON TOP of the engine's s_volume/ogg_volume cvars, so
 *                   the in-game Options sliders keep working and are never
 *                   overwritten.
 *
 * Who owns the session: WE do. Unlike the SDL-based ports (see
 * ~/dev/IOS-AUDIO-SESSION-GUIDE.md trap 1), this port has no SDL — the CoreAudio
 * RemoteIO driver in snddma_coreaudio.m is the only thing that touches
 * AVAudioSession, and it calls Q2_iOS_AudioApply() before its setActive:YES.
 * That matters because the first activation is the only one that can interrupt
 * other apps' audio (trap 2): a category set after S_Init would make "Stop Other
 * Audio" a no-op on the launch the player chose it.
 *
 * iOS can still hand the session back with different options after an
 * interruption or a route change, so the observers below plus a cheap 4 Hz poll
 * re-assert what we asked for.
 */
#import "ios_audio.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <math.h>

extern void  S_SetExternalGain(float g);         // engine: sound/dma.c, overlay patch 0021
extern int   VID_iOS_AudioMode(void);            // ios_bridge.m — ios_audio_mode cvar
extern float VID_iOS_Volume(void);               // ios_bridge.m — ios_volume cvar

// How far "Lower Game Audio" pulls the game down: -13 dB. Loud enough to still
// hear the strogg behind you, quiet enough to follow a podcast over it.
#define Q2_DUCK_GAIN 0.22f
// Gain ramp time constant. A hard cut when music starts is audible as a click on
// a sustained ambient loop; ~0.2 s of exponential glide is not.
#define Q2_GAIN_TAU  0.20f

NSArray<NSString *> *Q2_iOS_AudioModeTitles(void)
{
    return @[ @"Stop Other Audio", @"Play Both", @"Lower Other Audio", @"Lower Game Audio", @"Mute Game Audio" ];
}

// "Duck" and "mix" mean nothing to a player — every option gets a sentence.
NSArray<NSString *> *Q2_iOS_AudioModeDetails(void)
{
    return @[
        @"Music and podcasts stop when Quake II starts.",
        @"Both play together, neither one quieter.",
        @"Music and podcasts drop to the background; game audio stays full.",
        @"Game audio drops to the background while another app is playing.",
        @"Game audio goes silent while another app is playing.",
    ];
}

static Q2AudioMode q2_audio_mode(void)
{
    int m = VID_iOS_AudioMode();
    if (m < 0 || m >= Q2_AUDIO_MODE_COUNT)
        m = Q2_AUDIO_DUCK_OTHERS;
    return (Q2AudioMode)m;
}

// The category/options this mode wants. Playback throughout — a game should keep
// playing with the ring/silent switch off, which is what Playback buys over
// Ambient; only the mixability bits differ.
static AVAudioSessionCategoryOptions q2_audio_options(Q2AudioMode m)
{
    switch (m) {
    case Q2_AUDIO_STOP_OTHERS:
        return 0;   // non-mixable: activating the session interrupts the other app
    case Q2_AUDIO_DUCK_OTHERS:
        return AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDuckOthers;
    default:
        return AVAudioSessionCategoryOptionMixWithOthers;   // we do our own attenuating, if any
    }
}

// ---------------------------------------------------------------------------
static BOOL   q2_other_playing;     // cached: another app is producing audio
static float  q2_gain_target = 1;   // where the mix gain is heading
static float  q2_gain_cur = -1;     // what the engine currently has (-1 = never set)
static double q2_poll_last;

static BOOL q2_query_other_playing(AVAudioSession *s)
{
    // isOtherAudioPlaying is the broad "someone else has sound out";
    // secondaryAudioShouldBeSilencedHint is the narrower "another app is playing
    // PRIMARY audio (Music, a podcast)". Either means the player is listening to
    // something that is not us.
    return s.isOtherAudioPlaying || s.secondaryAudioShouldBeSilencedHint;
}

static void q2_audio_recompute_target(void)
{
    Q2AudioMode m = q2_audio_mode();
    float duck = 1.0f;
    if (q2_other_playing) {
        if (m == Q2_AUDIO_DUCK_GAME)      duck = Q2_DUCK_GAIN;
        else if (m == Q2_AUDIO_MUTE_GAME) duck = 0.0f;
    }
    float master = fmaxf(0.0f, fminf(1.0f, VID_iOS_Volume()));
    float t = master * duck;
    if (fabsf(t - q2_gain_target) > 0.0005f)
        NSLog(@"[q2repro] audio: mix gain -> %.2f (volume %.2f, duck %.2f, other %s)",
              t, master, duck, q2_other_playing ? "yes" : "no");
    q2_gain_target = t;
}

void Q2_iOS_AudioApply(void)
{
    AVAudioSession *s = AVAudioSession.sharedInstance;
    Q2AudioMode m = q2_audio_mode();
    AVAudioSessionCategoryOptions want = q2_audio_options(m);
    NSError *err = nil;

    if (![s.category isEqualToString:AVAudioSessionCategoryPlayback] || s.categoryOptions != want) {
        if (![s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:want error:&err])
            NSLog(@"[q2repro] audio: setCategory(mode %d, opts %lu) failed: %@", (int)m, (unsigned long)want, err);
        else
            NSLog(@"[q2repro] audio: session -> Playback opts %lu (mode %d)", (unsigned long)want, (int)m);
    }

    // Switching TO the non-mixable mode mid-session only interrupts the other app
    // when the session (re)activates, and setActive:YES on an already-active
    // session is a no-op — so if the other app is still going, bounce it once.
    // Losing that race is survivable: the category is now right, so the next
    // launch (where the driver's activation is the first one) interrupts cleanly.
    if (m == Q2_AUDIO_STOP_OTHERS) {
        [s setActive:YES error:nil];
        if (q2_query_other_playing(s)) {
            [s setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
            if (![s setActive:YES error:&err])
                NSLog(@"[q2repro] audio: reactivate to interrupt other audio failed: %@", err);
        }
    }

    q2_other_playing = q2_query_other_playing(s);
    q2_audio_recompute_target();
}

void Q2_iOS_AudioBoot(void)
{
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    // Each of these is a moment iOS may have handed the session back with
    // different options, or the "is anyone else playing" answer may have changed.
    for (NSNotificationName n in @[ AVAudioSessionRouteChangeNotification,
                                    AVAudioSessionInterruptionNotification,
                                    AVAudioSessionSilenceSecondaryAudioHintNotification,
                                    UIApplicationDidBecomeActiveNotification ])
        [nc addObserverForName:n object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) { Q2_iOS_AudioApply(); }];

    NSLog(@"[q2repro] audio: boot mode %d, volume %.2f", (int)q2_audio_mode(), VID_iOS_Volume());
}

void Q2_iOS_AudioTick(void)
{
    double now = CACurrentMediaTime();
    static double last_frame;
    double dt = last_frame ? now - last_frame : 0;
    last_frame = now;

    // Poll at 4 Hz: the notifications above cover the common cases, but nothing
    // posts when the player merely hits play in another app while we are
    // frontmost, and an interruption can return the session with other options.
    if (now - q2_poll_last >= 0.25) {
        q2_poll_last = now;
        AVAudioSession *s = AVAudioSession.sharedInstance;
        BOOL other = q2_query_other_playing(s);
        Q2AudioMode m = q2_audio_mode();
        if (other != q2_other_playing) {
            q2_other_playing = other;
            NSLog(@"[q2repro] audio: other app audio %s", other ? "started" : "stopped");
        }
        if (s.categoryOptions != q2_audio_options(m) || ![s.category isEqualToString:AVAudioSessionCategoryPlayback])
            Q2_iOS_AudioApply();   // something changed it under us — put it back
        q2_audio_recompute_target();
    }

    // Glide toward the target so duck/unduck and slider drags are not a step.
    if (q2_gain_cur < 0.0f) {
        q2_gain_cur = q2_gain_target;   // first frame: no ramp up from silence
    } else if (dt > 0 && dt < 0.5) {
        float a = 1.0f - expf(-(float)dt / Q2_GAIN_TAU);
        q2_gain_cur += (q2_gain_target - q2_gain_cur) * a;
        if (fabsf(q2_gain_target - q2_gain_cur) < 0.001f)
            q2_gain_cur = q2_gain_target;
    } else {
        q2_gain_cur = q2_gain_target;
    }

    static float applied = -1;
    if (q2_gain_cur != applied) {
        applied = q2_gain_cur;
        S_SetExternalGain(q2_gain_cur);
    }
}
