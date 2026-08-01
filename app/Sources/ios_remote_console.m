// ios_remote_console.m — dev-only remote console over the tailnet.
//
// The user is remote for weeks; Apple's device services (devicectl/Xcode) do NOT traverse the
// tailnet, but a plain TCP socket the app opens does. This gives a way to run engine console
// commands on the device from the dev machine over Tailscale — e.g. `touchedit print` to read a
// device-arranged touch layout and promote it to the shipped defaults (guide §3).
//
// It is an UNAUTHENTICATED command port, so per §6 it must never reach public users: the whole
// file compiles to no-ops unless Q2_DEV_BUILD (set by gen-app-project.sh only for 4-component
// OTA versions like 1.0.8.2; a 3-component release version → Q2_DEV_BUILD=0 → this is inert).
// Started/stopped from the "Remote Console" switch in the native iOS settings (also dev-gated).
#import <UIKit/UIKit.h>

void Q2_iOS_RemoteConsole(int on);
int  Q2_iOS_RemoteConsoleRunning(void);

#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>

extern void VID_iOS_Command(const char *cmd);

#define Q2_RCON_PORT 8770   // outside the HarbourMasters-reserved 8765–8769 range

// A SIMULATOR app shares the Mac's network stack, so 8770 can already be taken by
// something on this machine — the bind then fails silently and the console looks alive
// but answers nothing. Q2_RCON_PORT in the environment (SIMCTL_CHILD_Q2_RCON_PORT)
// moves it. Devices have their own stack and never need this.
static int q2_rcon_port(void)
{
    const char *e = getenv("Q2_RCON_PORT");
    int p = e ? atoi(e) : 0;
    return (p > 0 && p < 65536) ? p : Q2_RCON_PORT;
}

@interface Q2RemoteConsole : NSObject
@property(nonatomic) BOOL running;
@end

@implementation Q2RemoteConsole {
    int _listenfd;
    dispatch_queue_t _q;
}
+ (instancetype)shared {
    static Q2RemoteConsole *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [Q2RemoteConsole new]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) { _listenfd = -1; _q = dispatch_queue_create("q2.rcon", DISPATCH_QUEUE_SERIAL); }
    return self;
}
- (NSString *)logPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"profile/baseq2/logs/console.log"];
}
- (void)start {
    if (_running) return;
    _running = YES;
    dispatch_async(_q, ^{ [self serve]; });
    NSLog(@"[q2repro] remote console: starting on tcp/%d (tailnet)", q2_rcon_port());
}
- (void)stop {
    _running = NO;
    if (_listenfd >= 0) { close(_listenfd); _listenfd = -1; }   // unblocks accept()
    NSLog(@"[q2repro] remote console: stopped");
}
- (void)serve {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { _running = NO; return; }
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = INADDR_ANY; addr.sin_port = htons(q2_rcon_port());
    // Loud, not silent: a failed bind used to leave "listening" in the log with nothing
    // actually accepting — the port was already taken by another process on the host.
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 1) < 0) {
        NSLog(@"[q2repro] remote console: bind/listen on tcp/%d FAILED (%s)", q2_rcon_port(), strerror(errno));
        close(fd); _running = NO; return;
    }
    NSLog(@"[q2repro] remote console: listening on tcp/%d", q2_rcon_port());
    _listenfd = fd;
    while (_running) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) break;                  // stop() closed the listener
        [self handleClient:c];
        close(c);
    }
    if (_listenfd >= 0) { close(_listenfd); _listenfd = -1; }
}
- (void)handleClient:(int)c {
    const char *banner = "q2repro remote console — type an engine command per line; its console output follows.\n";
    write(c, banner, strlen(banner));
    NSMutableData *line = [NSMutableData data];
    char buf[1024];
    while (_running) {
        ssize_t n = read(c, buf, sizeof(buf));
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                NSString *cmd = [[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding]
                                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                line = [NSMutableData data];
                if (cmd.length) [self runCommand:cmd sendTo:c];
            } else if (buf[i] != '\r') {
                [line appendBytes:&buf[i] length:1];
            }
        }
    }
}
// Run on the main thread (engine + UIKit), then stream back whatever it appended to the engine
// logfile — the capture channel (boot sets logfile_flush 1, so output lands synchronously).
- (void)runCommand:(NSString *)cmd sendTo:(int)c {
    NSString *log = [self logPath];
    unsigned long long before = [[NSFileManager.defaultManager attributesOfItemAtPath:log error:nil] fileSize];
    dispatch_sync(dispatch_get_main_queue(), ^{ VID_iOS_Command(cmd.UTF8String); });
    usleep(60000);   // let any deferred Cbuf output flush to the log
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:log];
    if (fh) {
        @try {
            [fh seekToFileOffset:before];
            NSData *d = [fh readDataToEndOfFile];
            if (d.length) write(c, d.bytes, d.length);
        } @catch (__unused id e) {}
        [fh closeFile];
    }
    const char *ok = "\n(ok)\n"; write(c, ok, strlen(ok));
}
@end

void Q2_iOS_RemoteConsole(int on) { if (on) [[Q2RemoteConsole shared] start]; else [[Q2RemoteConsole shared] stop]; }
int  Q2_iOS_RemoteConsoleRunning(void) { return [Q2RemoteConsole shared].running ? 1 : 0; }

#else   // public build — the command port does not exist
void Q2_iOS_RemoteConsole(int on) { (void)on; }
int  Q2_iOS_RemoteConsoleRunning(void) { return 0; }
#endif
