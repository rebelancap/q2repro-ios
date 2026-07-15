// ES3Probe — Phase 0.4 substrate spike.
// Minimal native EAGL OpenGL ES 3.0 app for the iPhone. Answers, on-device:
//   1. Does native EAGL GLES still create an ES 3.0 context on iOS 26? (Apple
//      deprecated GLES — if this returns nil, native ES 3.0 is dead → ANGLE forced.)
//   2. What are the exact caps? Specifically: is SSBO (ES 3.1) or a texture-buffer
//      (ES 3.2 / GL_EXT_texture_buffer) available? These gate q2repro's MD5 GPU
//      skeletal path (models.c). Native EAGL tops out at ES 3.0 → expect NEITHER.
//   3. What present cadence does CADisplayLink deliver at max rate (60 vs 120)?
//      Validates docs/pacing.md.
// Results are shown on a UILabel (screenshot it) AND NSLog'd (capture via console).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <mach/mach_time.h>

// ---- GL probe view (CAEAGLLayer-backed) ----------------------------------

@interface GLProbeView : UIView
@property(nonatomic, copy) void (^onReport)(NSString *summary, NSString *full);
@end

@implementation GLProbeView {
    EAGLContext *_ctx;
    GLuint _fbo, _colorRB, _program, _vbo, _vao;
    GLint _fbW, _fbH;
    GLint _uAngle;
    CADisplayLink *_link;
    double _angle;
    // cadence measurement
    CFTimeInterval _lastTs;
    int _frames;
    double _sumInterval, _minInterval, _maxInterval;
    BOOL _reported;
    NSString *_caps;
    NSString *_fullReport;
}

+ (Class)layerClass { return [CAEAGLLayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentScaleFactor = UIScreen.mainScreen.nativeScale;
        CAEAGLLayer *l = (CAEAGLLayer *)self.layer;
        l.opaque = YES;
        l.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking : @NO,
                                  kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8 };
        _ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
        if (!_ctx) {
            NSLog(@"[ES3Probe] FATAL: kEAGLRenderingAPIOpenGLES3 context is nil — native ES 3.0 unavailable on this OS.");
            _caps = @"ES3 CONTEXT = nil (native GLES dead)";
            return self;
        }
        [EAGLContext setCurrentContext:_ctx];
        _minInterval = 1e9;
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && _ctx && !_link) {
        [self buildGL];
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) {
            _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120); // ask for up to 120
        }
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (NSString *)glStr:(GLenum)e { const GLubyte *s = glGetString(e); return s ? @((const char *)s) : @"(null)"; }

- (void)buildGL {
    // Framebuffer bound to the drawable.
    glGenFramebuffers(1, &_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
    glGenRenderbuffers(1, &_colorRB);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRB);
    [_ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRB);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_fbW);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_fbH);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        NSLog(@"[ES3Probe] framebuffer incomplete");

    // Rotating triangle (proves rendering + a real ES 3.00 shader compile).
    static const char *vs =
        "#version 300 es\n"
        "in vec2 a_pos; in vec3 a_col; out vec3 v_col; uniform float u_angle;\n"
        "void main(){ float c=cos(u_angle), s=sin(u_angle);\n"
        "  mat2 r=mat2(c,-s,s,c); v_col=a_col; gl_Position=vec4(r*a_pos,0.0,1.0);}";
    static const char *fs =
        "#version 300 es\nprecision mediump float;\n"
        "in vec3 v_col; out vec4 o; void main(){ o=vec4(v_col,1.0);} ";
    _program = [self linkVS:vs FS:fs];
    _uAngle = glGetUniformLocation(_program, "u_angle");

    static const float verts[] = {
        0.0f, 0.6f,   1,0,0,
       -0.6f,-0.5f,   0,1,0,
        0.6f,-0.5f,   0,0,1 };
    glGenVertexArrays(1, &_vao);
    glBindVertexArray(_vao);
    glGenBuffers(1, &_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, _vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
    GLint aPos = glGetAttribLocation(_program, "a_pos");
    GLint aCol = glGetAttribLocation(_program, "a_col");
    glEnableVertexAttribArray(aPos);
    glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 5*sizeof(float), (void*)0);
    glEnableVertexAttribArray(aCol);
    glVertexAttribPointer(aCol, 3, GL_FLOAT, GL_FALSE, 5*sizeof(float), (void*)(2*sizeof(float)));

    [self queryCaps];
}

- (GLuint)linkVS:(const char *)vsrc FS:(const char *)fsrc {
    GLuint v = [self compile:GL_VERTEX_SHADER src:vsrc];
    GLuint f = [self compile:GL_FRAGMENT_SHADER src:fsrc];
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f); glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { char log[1024]; glGetProgramInfoLog(p, sizeof(log), NULL, log); NSLog(@"[ES3Probe] link fail: %s", log); }
    return p;
}
- (GLuint)compile:(GLenum)type src:(const char *)src {
    GLuint s = glCreateShader(type); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof(log), NULL, log); NSLog(@"[ES3Probe] compile fail: %s", log); }
    return s;
}

- (void)queryCaps {
    NSString *exts = [self glStr:GL_EXTENSIONS];
    BOOL bufTex = [exts containsString:@"texture_buffer"];      // GL_EXT/OES_texture_buffer (ES 3.2)
    BOOL ssbo   = [exts containsString:@"shader_storage"];      // never core-exposed on ES 3.0 EAGL
    BOOL aniso  = [exts containsString:@"texture_filter_anisotropic"];
    BOOL colFloat = [exts containsString:@"color_buffer_float"];
    GLint maxTex=0, maxSamples=0, maxUBO=0, maxVaryings=0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTex);
    glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
    glGetIntegerv(GL_MAX_UNIFORM_BUFFER_BINDINGS, &maxUBO);
    glGetIntegerv(GL_MAX_VARYING_VECTORS, &maxVaryings);

    BOOL md5Capable = ssbo || bufTex;
    NSString *full = [NSString stringWithFormat:
        @"GL_VERSION: %@\nGL_SL_VERSION: %@\nGL_RENDERER: %@\nGL_VENDOR: %@\n"
        @"drawable: %dx%d  nativeScale: %.2f  screen.maxFPS: %ld\n"
        @"MAX_TEXTURE_SIZE: %d  MAX_SAMPLES: %d  MAX_UBO_BINDINGS: %d  MAX_VARYINGS: %d\n"
        @"SSBO(ES3.1): %@   buffer_texture(ES3.2): %@   => MD5 GPU-skeletal capable: %@\n"
        @"anisotropic: %@   color_buffer_float: %@\n"
        @"EXTENSIONS:\n%@",
        [self glStr:GL_VERSION], [self glStr:GL_SHADING_LANGUAGE_VERSION],
        [self glStr:GL_RENDERER], [self glStr:GL_VENDOR],
        _fbW, _fbH, (double)UIScreen.mainScreen.nativeScale, (long)UIScreen.mainScreen.maximumFramesPerSecond,
        maxTex, maxSamples, maxUBO, maxVaryings,
        ssbo?@"YES":@"NO", bufTex?@"YES":@"NO", md5Capable?@"YES":@"NO",
        aniso?@"YES":@"NO", colFloat?@"YES":@"NO", exts];
    _caps = [NSString stringWithFormat:
        @"%@ / SL %@\n%@\ndrawable %dx%d @%.0fx  maxFPS %ld\n"
        @"SSBO:%@  bufTex:%@  → MD5-capable:%@",
        [self glStr:GL_VERSION], [self glStr:GL_SHADING_LANGUAGE_VERSION], [self glStr:GL_RENDERER],
        _fbW,_fbH,(double)UIScreen.mainScreen.nativeScale, (long)UIScreen.mainScreen.maximumFramesPerSecond,
        ssbo?@"YES":@"NO", bufTex?@"YES":@"NO", md5Capable?@"YES":@"NO"];
    NSLog(@"[ES3Probe] ==== CAPS ====\n%@", full);
    _fullReport = full;
}

- (void)tick:(CADisplayLink *)link {
    // cadence measurement (first ~2s)
    CFTimeInterval ts = link.timestamp;
    if (_lastTs > 0) {
        double dt = ts - _lastTs;
        _sumInterval += dt; _frames++;
        if (dt < _minInterval) _minInterval = dt;
        if (dt > _maxInterval) _maxInterval = dt;
    }
    _lastTs = ts;

    _angle += 0.03;
    glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
    glViewport(0, 0, _fbW, _fbH);
    glClearColor(0.06f, 0.07f, 0.10f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(_program);
    glUniform1f(_uAngle, (float)_angle);
    glBindVertexArray(_vao);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRB);
    [_ctx presentRenderbuffer:GL_RENDERBUFFER];

    if (!_reported && _frames >= 120) {   // ~1-2s of data
        _reported = YES;
        double avg = _sumInterval / _frames;
        NSString *cadence = [NSString stringWithFormat:@"cadence avg %.2fms (%.1f Hz)  min %.2f  max %.2f over %d frames",
                             avg*1000.0, 1.0/avg, _minInterval*1000.0, _maxInterval*1000.0, _frames];
        NSLog(@"[ES3Probe] %@", cadence);
        NSString *summary = [NSString stringWithFormat:@"%@\n%@", _caps, cadence];
        if (self.onReport) self.onReport(summary, [NSString stringWithFormat:@"%@\n%@", _fullReport, cadence]);
    }
}
@end

// ---- View controller: GL view + overlay label ----------------------------

@interface ProbeVC : UIViewController @end
@implementation ProbeVC {
    UILabel *_label;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    GLProbeView *gl = [[GLProbeView alloc] initWithFrame:self.view.bounds];
    gl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:gl];

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.numberOfLines = 0;
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    _label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _label.text = @"initializing ES3 context…";
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [_label.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
    ]];
    __weak UILabel *wl = _label;
    gl.onReport = ^(NSString *summary, NSString *full){
        dispatch_async(dispatch_get_main_queue(), ^{ wl.text = summary; });
    };
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

// ---- App delegate + main -------------------------------------------------

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
