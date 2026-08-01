// ios_settings_ui.m — native UIKit iOS settings panel.
//
// The other iOS ports keep their settings in a native window rather than the engine's text
// .menu system, and this port does the same: it is easier to manage and it decouples us
// from a fragile menu-file search-path bug that made "iOS Settings" vanish on rerelease
// installs. This panel reads/writes the same ios_* (and a few engine) cvars the old engine menu
// did — reads via VID_iOS_CvarValue, writes via `set <cvar> <v>` — so behaviour is identical,
// but every slider now shows its value and "Edit Touch Layout" has a clear home.
//
// Presented by Q2_iOS_PresentSettings (main.m) from the game view controller; reached from the
// engine menu's "iOS settings" entry and a gear button in the touch chrome, both of which run
// the `ios_settings` console command (ios_bridge.m).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ios_audio.h"

extern void  VID_iOS_Command(const char *cmd);
extern float VID_iOS_CvarValue(const char *name);
extern void  Q2_iOS_RemoteConsole(int on);       // dev-only tailnet console (ios_remote_console.m)
extern int   Q2_iOS_RemoteConsoleRunning(void);

typedef NSString * (^Q2Fmt)(float);
static const void *kCvarKey = &kCvarKey;   // stable associated-object key (switch rows → cvar)
static void SetCvar(NSString *cvar, float v) {
    VID_iOS_Command([NSString stringWithFormat:@"set %@ %.4g", cvar, v].UTF8String);
}

// ---- slider cell: title · live value · slider -------------------------------
@interface Q2SliderCell : UITableViewCell
@property(nonatomic, strong) UILabel  *titleLbl;
@property(nonatomic, strong) UILabel  *valueLbl;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy)   NSString *cvar;
@property(nonatomic, copy)   Q2Fmt     fmt;
@end
@implementation Q2SliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _titleLbl = [UILabel new]; _titleLbl.font = [UIFont systemFontOfSize:16];
        _valueLbl = [UILabel new];
        _valueLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _valueLbl.textColor = UIColor.secondaryLabelColor;
        _valueLbl.textAlignment = NSTextAlignmentRight;
        _slider = [UISlider new];
        [_slider addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
        for (UIView *v in @[_titleLbl, _valueLbl, _slider]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:v]; }
        [NSLayoutConstraint activateConstraints:@[
            [_titleLbl.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLbl.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_valueLbl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_valueLbl.centerYAnchor constraintEqualToAnchor:_titleLbl.centerYAnchor],
            [_valueLbl.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLbl.trailingAnchor constant:8],
            [_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_slider.topAnchor constraintEqualToAnchor:_titleLbl.bottomAnchor constant:6],
            [_slider.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}
- (void)refreshValue { _valueLbl.text = _fmt ? _fmt(_slider.value) : [NSString stringWithFormat:@"%.2f", _slider.value]; }
- (void)changed { SetCvar(_cvar, _slider.value); [self refreshValue]; }
@end

// ---- segmented cell: title · segmented control ------------------------------
@interface Q2SegmentCell : UITableViewCell
@property(nonatomic, strong) UISegmentedControl *seg;
@property(nonatomic, copy)   NSString *cvar;
@property(nonatomic, strong) NSArray  *values;   // NSNumber per segment
@end
@implementation Q2SegmentCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
- (void)changed {
    NSInteger i = _seg.selectedSegmentIndex;
    if (i >= 0 && i < (NSInteger)_values.count) SetCvar(_cvar, [_values[i] floatValue]);
}
@end

// ---- one-of-N picker (pushed from a "choice" row) ---------------------------
// Each option carries a sentence saying what it actually does. That is the whole
// point of the Audio section: "duck" and "mix" mean nothing to a player, and a
// four-word label would not help either.
@interface Q2ChoiceVC : UITableViewController
@property(nonatomic, copy) NSArray<NSString *> *titles, *details;
@property(nonatomic, copy) NSString *cvar;
@property(nonatomic, copy) void (^onPick)(void);
@end
@implementation Q2ChoiceVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _titles.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text = _titles[ip.row];
    c.detailTextLabel.text = _details[ip.row];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;   // let the explanation wrap rather than truncate
    int cur = (int)lroundf(VID_iOS_CvarValue(_cvar.UTF8String));
    c.accessoryType = (ip.row == cur) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    SetCvar(_cvar, (float)ip.row);
    [t reloadData];
    if (_onPick) _onPick();
    // Let the checkmark land before backing out, so the choice is visibly taken.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.navigationController popViewControllerAnimated:YES];
    });
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

// ---- the panel --------------------------------------------------------------
@interface Q2SettingsVC : UITableViewController
- (NSDictionary *)rowAt:(NSIndexPath *)ip;   // exposed for the console test seam below
@end
@implementation Q2SettingsVC {
    NSArray<NSDictionary *> *_sections;   // each: {title, rows:[rowDict...]}
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iOS Settings";
    // Explicit "Done" text (not the system item, which iOS 26 can render as an ambiguous glyph)
    // so there is never any doubt how to get back to the game.
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done)];

    Q2Fmt mult  = ^NSString *(float v){ return [NSString stringWithFormat:@"%.2f×", v / 3.0f]; };  // 3 = neutral 1.0×
    Q2Fmt gyro  = ^NSString *(float v){ return v < 0.05f ? @"Off" : [NSString stringWithFormat:@"%.1f", v]; };
    Q2Fmt pct   = ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f%%", v * 100.0f]; };
    Q2Fmt whole = ^NSString *(float v){ return [NSString stringWithFormat:@"%.0f", v]; };
    Q2Fmt mulx  = ^NSString *(float v){ return [NSString stringWithFormat:@"%.1f×", v]; };

    NSMutableArray *sections = [@[
      @{ @"title": @"Aim", @"rows": @[
          @{ @"kind": @"slider", @"title": @"Horizontal Sensitivity", @"cvar": @"ios_sens_x", @"min": @1, @"max": @6, @"fmt": mult },
          @{ @"kind": @"slider", @"title": @"Vertical Sensitivity",   @"cvar": @"ios_sens_y", @"min": @1, @"max": @6, @"fmt": mult },
          @{ @"kind": @"toggle", @"title": @"Invert Look",            @"cvar": @"ios_invert_y" },
          @{ @"kind": @"slider", @"title": @"Gyro Aim",               @"cvar": @"ios_gyro",   @"min": @0, @"max": @3, @"fmt": gyro },
      ]},
      @{ @"title": @"Touch Controls", @"rows": @[
          @{ @"kind": @"button", @"title": @"Edit Touch Layout…",     @"cmd": @"touchedit" },
          @{ @"kind": @"slider", @"title": @"Control Opacity",        @"cvar": @"ios_touch_alpha", @"min": @(0.4), @"max": @(1.5), @"fmt": pct },
          @{ @"kind": @"toggle", @"title": @"Fire Haptics",           @"cvar": @"ios_haptics" },
      ]},
      // Master gain on top of the engine's own Sound/Music Volume cvars, so this
      // never overwrites what the in-game Options menu is set to — and, critically,
      // the ducking applied by the modes below is never written back to config.cfg
      // (that ratchets the player's real volume down over days). See ios_audio.m.
      @{ @"title": @"Audio", @"rows": @[
          @{ @"kind": @"slider", @"title": @"Game Volume", @"cvar": @"ios_volume", @"min": @0, @"max": @1, @"fmt": pct },
          @{ @"kind": @"choice", @"title": @"Other App Audio", @"cvar": @"ios_audio_mode",
             @"titles": Q2_iOS_AudioModeTitles(), @"details": Q2_iOS_AudioModeDetails() },
      ]},
      @{ @"title": @"Display", @"rows": @[
          // Brightness = the engine `intensity` texture multiplier. In the GLSL backend (this build)
          // it is NOT a CVAR_FILES cvar, so it applies live — unlike vid_gamma, which is baked into
          // textures on iOS (no hardware gamma ramp) and would need an fs_restart to take effect.
          @{ @"kind": @"slider", @"title": @"Brightness", @"cvar": @"intensity", @"min": @1, @"max": @3, @"fmt": mulx },
          @{ @"kind": @"segment", @"title": @"Refresh Rate", @"cvar": @"ios_display_fps",
             @"segTitles": @[@"Max", @"60 Hz"], @"segValues": @[@0, @60] },
          @{ @"kind": @"toggle", @"title": @"FPS Counter",           @"cvar": @"ios_fps" },
          @{ @"kind": @"slider", @"title": @"Menu Size",             @"cvar": @"ui_scale", @"min": @3, @"max": @7, @"fmt": whole },
          @{ @"kind": @"toggle", @"title": @"Always Run",            @"cvar": @"cl_run" },
      ]},
    ] mutableCopy];
#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
    // OTA-only: a remote console for reading device state (e.g. touchedit print) over the tailnet.
    // Compiled out of public releases entirely (Q2_DEV_BUILD=0). See ios_remote_console.m.
    [sections addObject:@{ @"title": @"Developer (OTA build)", @"rows": @[
        @{ @"kind": @"rcon", @"title": @"Remote Console", @"detail": @"Listens on tcp/8770 over the tailnet" },
    ]}];
#endif
    _sections = sections;
}

// Popping back from a picker: refresh so the choice row's summary shows the new pick.
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }

- (NSDictionary *)rowAt:(NSIndexPath *)ip { return _sections[ip.section][@"rows"][ip.row]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _sections.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return [_sections[s][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return _sections[s][@"title"]; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = [self rowAt:ip];
    NSString *kind = r[@"kind"];
    if ([kind isEqualToString:@"slider"]) {
        Q2SliderCell *c = [t dequeueReusableCellWithIdentifier:@"sl"] ?: [[Q2SliderCell alloc] initWithStyle:0 reuseIdentifier:@"sl"];
        c.titleLbl.text = r[@"title"]; c.cvar = r[@"cvar"]; c.fmt = r[@"fmt"];
        c.slider.minimumValue = [r[@"min"] floatValue]; c.slider.maximumValue = [r[@"max"] floatValue];
        c.slider.value = VID_iOS_CvarValue([r[@"cvar"] UTF8String]);
        [c refreshValue];
        return c;
    }
    if ([kind isEqualToString:@"segment"]) {
        Q2SegmentCell *c = [t dequeueReusableCellWithIdentifier:@"sg"] ?: [[Q2SegmentCell alloc] initWithStyle:0 reuseIdentifier:@"sg"];
        if (!c.seg) {
            c.seg = [[UISegmentedControl alloc] initWithItems:r[@"segTitles"]];
            [c.seg addTarget:c action:@selector(changed) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = c.seg;
        }
        c.textLabel.text = r[@"title"]; c.cvar = r[@"cvar"]; c.values = r[@"segValues"];
        float cur = VID_iOS_CvarValue([r[@"cvar"] UTF8String]);
        NSUInteger sel = 0;
        for (NSUInteger i = 0; i < c.values.count; i++) if (fabsf([c.values[i] floatValue] - cur) < 0.5f) sel = i;
        c.seg.selectedSegmentIndex = sel;
        return c;
    }
    if ([kind isEqualToString:@"choice"]) {   // taps through to the one-of-N picker
        UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"ch"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"ch"];
        c.textLabel.text = r[@"title"];
        NSArray *titles = r[@"titles"];
        int cur = (int)lroundf(VID_iOS_CvarValue([r[@"cvar"] UTF8String]));
        c.detailTextLabel.text = (cur >= 0 && cur < (int)titles.count) ? titles[cur] : @"";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if ([kind isEqualToString:@"toggle"]) {
        UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"tg"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"tg"];
        c.textLabel.text = r[@"title"]; c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = VID_iOS_CvarValue([r[@"cvar"] UTF8String]) > 0.5f;
        objc_setAssociatedObject(sw, kCvarKey, r[@"cvar"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if ([kind isEqualToString:@"rcon"]) {   // dev-only remote console on/off (not a cvar)
        UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"rc"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"rc"];
        c.textLabel.text = r[@"title"];
        c.detailTextLabel.text = r[@"detail"]; c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new];
        sw.on = Q2_iOS_RemoteConsoleRunning() != 0;
        [sw addTarget:self action:@selector(rconChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    // button
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"bt"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"bt"];
    c.textLabel.text = r[@"title"]; c.textLabel.textColor = self.view.tintColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)toggleChanged:(UISwitch *)sw {
    NSString *cvar = objc_getAssociatedObject(sw, kCvarKey);
    SetCvar(cvar, sw.isOn ? 1 : 0);
}
- (void)rconChanged:(UISwitch *)sw { Q2_iOS_RemoteConsole(sw.isOn ? 1 : 0); }

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *r = [self rowAt:ip];
    if ([r[@"kind"] isEqualToString:@"choice"]) {
        Q2ChoiceVC *vc = [Q2ChoiceVC new];
        vc.title = r[@"title"];
        vc.titles = r[@"titles"]; vc.details = r[@"details"]; vc.cvar = r[@"cvar"];
        // "Stop Other Audio" has to re-activate the session to interrupt the other
        // app, so the choice must reach the policy layer the moment it is made —
        // not at the next 4 Hz poll, which only re-asserts the category.
        vc.onPick = ^{ Q2_iOS_AudioApply(); };
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    NSString *cmd = r[@"cmd"];
    if (cmd) {
        // Dismiss first so a command like `touchedit` shows its result over the game, not us.
        [self dismissViewControllerAnimated:YES completion:^{ VID_iOS_Command(cmd.UTF8String); }];
    }
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
// Landscape on BOTH platforms: the app's Info.plist is landscape-only, and on visionOS the
// autorotation machinery still runs on our modal (below), so the reported orientation must
// intersect the app's or UIKit aborts.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

// The nav controller that wraps the panel. visionOS presents a modal as an ornament-platter
// sheet and runs the iOS autorotation machinery on THIS wrapping controller — and a plain
// UINavigationController does NOT forward supportedInterfaceOrientations to its top view
// controller, so Q2SettingsVC's override never reached it. A bare present therefore aborted
// with UIApplicationInvalidInterfaceOrientation ("no common orientation with the application")
// because the app is landscape-only. Report landscape here so the intersection is never empty.
@interface Q2SettingsNav : UINavigationController
@end
@implementation Q2SettingsNav
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

// Weak ref to the live panel, for the console test seam below.
static __weak Q2SettingsVC *g_settingsVC;

// q2_settings_probe <row title substring> [select] — headless "scroll to / tap this
// settings row". Synthetic UIKit touches never reach the simulator's real touch path
// (the same reason q2_faketouch exists for the layout editor), and driving the Mac's UI
// with System Events needs Accessibility permission a headless session does not have.
// So this scrolls the row into view and, with `select`, calls the SAME delegate method a
// finger does — which is what makes the Audio section and its picker screenshot-able.
void Q2_iOS_SettingsProbe(const char *want, int select) {
    Q2SettingsVC *vc = g_settingsVC;
    if (!vc || !want || !*want) { NSLog(@"[q2repro] settings probe: no panel open"); return; }
    NSString *needle = @(want);
    for (NSInteger s = 0; s < [vc numberOfSectionsInTableView:vc.tableView]; s++) {
        for (NSInteger r = 0; r < [vc tableView:vc.tableView numberOfRowsInSection:s]; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            NSString *title = [vc rowAt:ip][@"title"];
            if ([title rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            NSLog(@"[q2repro] settings probe: %s '%@' (%ld,%ld)", select ? "selecting" : "scrolling to",
                  title, (long)s, (long)r);
            [vc.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
            if (select) [vc tableView:vc.tableView didSelectRowAtIndexPath:ip];
            return;
        }
    }
    NSLog(@"[q2repro] settings probe: no row matching '%@'", needle);
}

// Factory used by main.m's Q2_iOS_PresentSettings — returns a nav-wrapped panel, dark-styled.
UIViewController *Q2_iOS_NewSettingsVC(void) {
    Q2SettingsVC *vc = [Q2SettingsVC new];
    g_settingsVC = vc;
    Q2SettingsNav *nav = [[Q2SettingsNav alloc] initWithRootViewController:vc];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFullScreen;   // iOS covers the game; visionOS coerces to a sheet
    return nav;
}
