// ios_audio.h — "what happens to game sound when another app is already playing".
// Five player-facing modes; see ios_audio.m and ~/dev/IOS-AUDIO-SESSION-GUIDE.md.
#pragma once
#import <Foundation/Foundation.h>

typedef enum {
    Q2_AUDIO_STOP_OTHERS = 0,   // non-mixable session: the other app is interrupted
    Q2_AUDIO_MIX         = 1,   // both play, neither one quieter
    Q2_AUDIO_DUCK_OTHERS = 2,   // iOS lowers the other app (default)
    Q2_AUDIO_DUCK_GAME   = 3,   // WE lower ourselves while the other app plays
    Q2_AUDIO_MUTE_GAME   = 4,   // WE go silent while the other app plays
    Q2_AUDIO_MODE_COUNT
} Q2AudioMode;

// Row titles / one-line explanations for the settings picker (index = mode).
NSArray<NSString *> *Q2_iOS_AudioModeTitles(void);
NSArray<NSString *> *Q2_iOS_AudioModeDetails(void);

// Install the route-change/interruption/foreground observers. Called once, right
// after Qcommon_Init (the session category itself is set from the CoreAudio
// driver's init, which is the FIRST activation — see ios_audio.m).
void Q2_iOS_AudioBoot(void);
// Re-assert the session category/options for the current mode and recompute the
// mix gain. Called from the CoreAudio driver before it activates the session, and
// whenever the settings panel changes a value.
void Q2_iOS_AudioApply(void);
// Per-frame: polls "is another app playing" at 4 Hz and ramps the engine mix gain.
void Q2_iOS_AudioTick(void);
