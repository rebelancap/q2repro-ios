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

// visionOS sound-stage anchoring. Q2_iOS_AudioApply() re-sets the session CATEGORY from
// six places (driver init, foreground re-activate, four notification observers, the 4 Hz
// drift poll, the settings picker) and in STOP_OTHERS mode bounces setActive — every one
// of which can drop the intended spatial experience. So the DESIRED mode is stored here
// and re-asserted at the end of every Apply, instead of being set once from the shell.
typedef enum {
    Q2_SPATIAL_AUTOMATIC = 0,   // 2D window: head-tracked, automatic anchoring
    Q2_SPATIAL_FRONT     = 1,   // 3D panel: head-tracked, anchored FRONT (at the screen)
    Q2_SPATIAL_BYPASSED  = 2,   // VR: bypass the spatializer entirely (charter D8)
} Q2SpatialMode;
void Q2_iOS_SetSpatialMode(int mode);   // record + apply now
int  Q2_iOS_SpatialMode(void);          // what is currently asked for (for SETTINGSNOW)
