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

// ---- the panel --------------------------------------------------------------
@interface Q2SettingsVC : UITableViewController
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
    NSString *cmd = r[@"cmd"];
    if (cmd) {
        // Dismiss first so a command like `touchedit` shows its result over the game, not us.
        [self dismissViewControllerAnimated:YES completion:^{ VID_iOS_Command(cmd.UTF8String); }];
    }
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
#if !TARGET_OS_VISION
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
#endif
@end

// Factory used by main.m's Q2_iOS_PresentSettings — returns a nav-wrapped panel, dark-styled.
UIViewController *Q2_iOS_NewSettingsVC(void) {
    Q2SettingsVC *vc = [Q2SettingsVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}
