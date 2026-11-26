#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Photos/Photos.h>
#import <Vision/Vision.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/wait.h>
#import <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "tapcore.h"

// ---------------- IOKit & Private API Definitions ----------------
typedef void *IOHIDEventRef;
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDServiceClientRef;
typedef double IOHIDFloat;

enum {
    kIOHIDDigitizerTransducerTypeFinger = 2,
    kIOHIDDigitizerTransducerTypeHand   = 3,
};

enum {
    kIOHIDDigitizerEventRange    = 1 << 0,
    kIOHIDDigitizerEventTouch    = 1 << 1,
    kIOHIDDigitizerEventPosition = 1 << 2,
};

#define kIOHIDEventFieldDigitizerIsDisplayIntegrated ((11 << 16) | 25)
#define TAPCORE_IPC_PORT 3001
#define TAPCORE_NOTIFY_CMD "com.tapcore.cmd"

// KEY_TYPE constants exposed to Lua
enum {
    TAPCORE_KEY_HOME        = 1,
    TAPCORE_KEY_VOLUME_DOWN = 2,
    TAPCORE_KEY_VOLUME_UP   = 3,
    TAPCORE_KEY_POWER       = 4,
};

static IOHIDEventSystemClientRef (*p_IOHIDEventSystemClientCreate)(CFAllocatorRef);
static CFArrayRef (*p_IOHIDEventSystemClientCopyServices)(IOHIDEventSystemClientRef);
static CFTypeRef (*p_IOHIDServiceClientCopyProperty)(IOHIDServiceClientRef, CFStringRef);
static CFTypeRef (*p_IOHIDServiceClientGetRegistryID)(IOHIDServiceClientRef);
static void (*p_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef, IOHIDEventRef);
static IOHIDEventRef (*p_IOHIDEventCreateDigitizerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, uint32_t);
static IOHIDEventRef (*p_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, Boolean, Boolean, uint32_t);
static IOHIDEventRef (*p_IOHIDEventCreateKeyboardEvent)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
static void (*p_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*p_IOHIDEventSetIntegerValue)(IOHIDEventRef, uint32_t, CFIndex);
static void (*p_IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t);

// Recorder HID callback APIs
typedef void (*TapCoreHIDEventCallback)(void *target, void *refcon, IOHIDServiceClientRef service, IOHIDEventRef event);
static void (*p_IOHIDEventSystemClientRegisterEventCallback)(IOHIDEventSystemClientRef, TapCoreHIDEventCallback, void *, void *);
static void (*p_IOHIDEventSystemClientUnregisterEventCallback)(IOHIDEventSystemClientRef);
static void (*p_IOHIDEventSystemClientScheduleWithRunLoop)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
static void (*p_IOHIDEventSystemClientUnscheduleWithRunLoop)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
static uint32_t (*p_IOHIDEventGetType)(IOHIDEventRef);
static CFArrayRef (*p_IOHIDEventGetChildren)(IOHIDEventRef);
static CFIndex (*p_IOHIDEventGetIntegerValue)(IOHIDEventRef, uint32_t);
static IOHIDFloat (*p_IOHIDEventGetFloatValue)(IOHIDEventRef, uint32_t);

static CFPropertyListRef (*p_MGCopyAnswer)(CFStringRef);
static void (*p_CARenderServerRenderDisplay)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);
static void (*p_BKSTerminateApplicationForReasonAndReportWithDescription)(CFStringRef, int, Boolean, CFStringRef);

// ---------------- Global Runtime State ----------------
static IOHIDEventSystemClientRef g_hidClient = NULL;
static uint64_t g_senderID = 0xDEFACEDBEEFCAFE5ULL;
static int g_screenW = 1125;
static int g_screenH = 2436;
static NSString *g_scriptsDir = nil;

static volatile int g_stopRequested = 0;

// Ring-buffer Live Logger (last 400 lines)
#define MAX_LOG_ENTRIES 400
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray<NSDictionary *> *g_logRing = nil;
static uint64_t g_logNextId = 1;

void tapcore_script_reset_stop(void)   { __sync_lock_test_and_set(&g_stopRequested, 0); }
void tapcore_script_request_stop(void) { __sync_lock_test_and_set(&g_stopRequested, 1); }
int  tapcore_script_should_stop(void)  { return __sync_fetch_and_add(&g_stopRequested, 0); }

int      tapcore_screen_width(void)  { return g_screenW; }
int      tapcore_screen_height(void) { return g_screenH; }
uint64_t tapcore_sender_id(void)     { return g_senderID; }

void tapcore_set_scripts_dir(NSString *dir) {
    if (dir.length > 0) g_scriptsDir = [dir copy];
}

NSString *tapcore_scripts_dir(void) {
    if (g_scriptsDir.length > 0) return g_scriptsDir;
    const char *env = getenv("TAPCORE_ROOT_DIR");
    if (env && env[0]) return [NSString stringWithUTF8String:env];
    return @TAPCORE_SCRIPTS_DIR;
}

void tapcore_log(const char *tag, const char *fmt, ...) {
    @autoreleasepool {
        char buf[1024];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);

        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm_now;
        localtime_r(&tv.tv_sec, &tm_now);
        char ts[32];
        snprintf(ts, sizeof(ts), "%02d:%02d:%02d.%03d",
                 tm_now.tm_hour, tm_now.tm_min, tm_now.tm_sec, (int)(tv.tv_usec / 1000));

        fprintf(stderr, "[%s][%s] %s\n", ts, tag ?: "SYS", buf);

        pthread_mutex_lock(&g_logLock);
        if (!g_logRing) g_logRing = [NSMutableArray arrayWithCapacity:MAX_LOG_ENTRIES + 8];
        uint64_t eid = g_logNextId++;
        [g_logRing addObject:@{
            @"id": @(eid),
            @"ts": [NSString stringWithUTF8String:ts],
            @"tag": [NSString stringWithUTF8String:tag ?: "SYS"],
            @"msg": [NSString stringWithUTF8String:buf]
        }];
        if (g_logRing.count > MAX_LOG_ENTRIES) {
            [g_logRing removeObjectAtIndex:0];
        }
        pthread_mutex_unlock(&g_logLock);
    }
}

NSArray *tapcore_logs_since(uint64_t sinceId) {
    pthread_mutex_lock(&g_logLock);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *entry in g_logRing) {
        if ([entry[@"id"] unsignedLongLongValue] > sinceId) {
            [out addObject:entry];
        }
    }
    pthread_mutex_unlock(&g_logLock);
    return out;
}

void tapcore_logs_clear(void) {
    pthread_mutex_lock(&g_logLock);
    [g_logRing removeAllObjects];
    pthread_mutex_unlock(&g_logLock);
}

static pthread_mutex_t g_surfaceLock = PTHREAD_MUTEX_INITIALIZER;
static IOSurfaceRef g_surface = NULL;

// IPC state for TapCoreInput.dylib (127.0.0.1:3001)
static pthread_mutex_t g_ipcLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_ipcCond = PTHREAD_COND_INITIALIZER;
static uint64_t g_ipcSeq = 0;
static uint64_t g_ipcAckSeq = 0;
static char g_ipcOp[32] = {0};
static char *g_ipcPayload = NULL;
static size_t g_ipcPayloadLen = 0;

// ---------------- Initialization ----------------
static uint64_t detectDigitizerSenderID(IOHIDEventSystemClientRef client) {
    uint64_t found = 0;
    CFArrayRef services = p_IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0xDEFACEDBEEFCAFE5ULL;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef regID = p_IOHIDServiceClientGetRegistryID(svc);
        uint64_t sid = 0;
        if (regID && CFGetTypeID(regID) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)regID, kCFNumberSInt64Type, &sid);
        CFTypeRef pageRef  = p_IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage"));
        CFTypeRef usageRef = p_IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage"));
        int page = -1, usage = -1;
        if (pageRef && CFGetTypeID(pageRef) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)pageRef, kCFNumberIntType, &page);
        if (usageRef && CFGetTypeID(usageRef) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)usageRef, kCFNumberIntType, &usage);
        if (page == 0x0D && (usage == 0x04 || usage == 0x05) && sid != 0 && found == 0) {
            found = sid;
        }
        if (pageRef) CFRelease(pageRef);
        if (usageRef) CFRelease(usageRef);
    }
    CFRelease(services);
    return found ? found : 0xDEFACEDBEEFCAFE5ULL;
}

static long long g_daemonStarted = 0;
long long tapcore_daemon_started(void) { return g_daemonStarted; }

int tapcore_core_init(void) {
    g_daemonStarted = (long long)time(NULL);
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) {
        fprintf(stderr, "[tapcore] dlopen IOKit failed: %s\n", dlerror());
        return -1;
    }
#define LOAD(lib, sym) do { p_##sym = dlsym(lib, #sym); if (!p_##sym) { fprintf(stderr, "[tapcore] Missing %s\n", #sym); return -2; } } while (0)
    LOAD(h, IOHIDEventSystemClientCreate);
    LOAD(h, IOHIDEventSystemClientCopyServices);
    LOAD(h, IOHIDServiceClientCopyProperty);
    LOAD(h, IOHIDServiceClientGetRegistryID);
    LOAD(h, IOHIDEventSystemClientDispatchEvent);
    LOAD(h, IOHIDEventCreateDigitizerEvent);
    LOAD(h, IOHIDEventCreateDigitizerFingerEvent);
    LOAD(h, IOHIDEventCreateKeyboardEvent);
    LOAD(h, IOHIDEventAppendEvent);
    LOAD(h, IOHIDEventSetIntegerValue);
    LOAD(h, IOHIDEventSetSenderID);
#undef LOAD

    // Optional symbols for HID Touch Recorder
    p_IOHIDEventSystemClientRegisterEventCallback   = dlsym(h, "IOHIDEventSystemClientRegisterEventCallback");
    p_IOHIDEventSystemClientUnregisterEventCallback = dlsym(h, "IOHIDEventSystemClientUnregisterEventCallback");
    p_IOHIDEventSystemClientScheduleWithRunLoop     = dlsym(h, "IOHIDEventSystemClientScheduleWithRunLoop");
    p_IOHIDEventSystemClientUnscheduleWithRunLoop   = dlsym(h, "IOHIDEventSystemClientUnscheduleWithRunLoop");
    p_IOHIDEventGetType                             = dlsym(h, "IOHIDEventGetType");
    p_IOHIDEventGetChildren                         = dlsym(h, "IOHIDEventGetChildren");
    p_IOHIDEventGetIntegerValue                     = dlsym(h, "IOHIDEventGetIntegerValue");
    p_IOHIDEventGetFloatValue                       = dlsym(h, "IOHIDEventGetFloatValue");

    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (mg) p_MGCopyAnswer = dlsym(mg, "MGCopyAnswer");

    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    if (qc) p_CARenderServerRenderDisplay = dlsym(qc, "CARenderServerRenderDisplay");

    void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    if (bbs) {
        p_BKSTerminateApplicationForReasonAndReportWithDescription =
            dlsym(bbs, "BKSTerminateApplicationForReasonAndReportWithDescription");
    }

    g_hidClient = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_hidClient) {
        fprintf(stderr, "[tapcore] IOHIDEventSystemClientCreate failed\n");
        return -3;
    }
    g_senderID = detectDigitizerSenderID(g_hidClient);

    double w = 1125.0, h_px = 2436.0;
    if (p_MGCopyAnswer) {
        CFNumberRef nw = (CFNumberRef)p_MGCopyAnswer(CFSTR("main-screen-width"));
        CFNumberRef nh = (CFNumberRef)p_MGCopyAnswer(CFSTR("main-screen-height"));
        if (nw) { CFNumberGetValue(nw, kCFNumberDoubleType, &w); CFRelease(nw); }
        if (nh) { CFNumberGetValue(nh, kCFNumberDoubleType, &h_px); CFRelease(nh); }
    }
    g_screenW = (int)w;
    g_screenH = (int)h_px;

    fprintf(stderr, "[tapcore] Init OK: screen=%dx%d senderID=0x%llx CARenderServer=%s\n",
            g_screenW, g_screenH, (unsigned long long)g_senderID,
            p_CARenderServerRenderDisplay ? "OK" : "MISSING");
    return 0;
}

// ---------------- IPC Server (127.0.0.1:3001) for TapCoreInput.dylib ----------------
static char g_ipcAckInfo[160] = {0};

static void *ipc_server_thread(void *arg) {
    (void)arg;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return NULL;
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(srv, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TAPCORE_IPC_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(srv, 32) != 0) {
        fprintf(stderr, "[tapcore] IPC bind 127.0.0.1:%d failed: %s\n", TAPCORE_IPC_PORT, strerror(errno));
        close(srv);
        return NULL;
    }
    fprintf(stderr, "[tapcore] IPC server listening on 127.0.0.1:%d\n", TAPCORE_IPC_PORT);

    for (;;) {
        int cfd = accept(srv, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            usleep(10000);
            continue;
        }
        struct timeval tv = {0, 200000};
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

        char line[128] = {0};
        size_t pos = 0;
        while (pos + 1 < sizeof(line)) {
            char c = 0;
            ssize_t r = recv(cfd, &c, 1, 0);
            if (r <= 0 || c == '\n') break;
            if (c != '\r') line[pos++] = c;
        }
        line[pos] = '\0';

        if (strcmp(line, "GET") == 0) {
            pthread_mutex_lock(&g_ipcLock);
            char hdr[128];
            int hn = snprintf(hdr, sizeof(hdr), "%llu %s %zu\n",
                              (unsigned long long)g_ipcSeq, g_ipcOp, g_ipcPayloadLen);
            if (hn > 0) send(cfd, hdr, (size_t)hn, 0);
            if (g_ipcPayload && g_ipcPayloadLen > 0) {
                send(cfd, g_ipcPayload, g_ipcPayloadLen, 0);
            }
            pthread_mutex_unlock(&g_ipcLock);
        } else if (strncmp(line, "ACK ", 4) == 0) {
            unsigned long long ackSeq = 0;
            char info[128] = {0};
            if (sscanf(line + 4, "%llu %127[^\n]", &ackSeq, info) >= 1) {
                pthread_mutex_lock(&g_ipcLock);
                if (ackSeq >= g_ipcAckSeq) {
                    g_ipcAckSeq = ackSeq;
                    strncpy(g_ipcAckInfo, info, sizeof(g_ipcAckInfo) - 1);
                    g_ipcAckInfo[sizeof(g_ipcAckInfo) - 1] = '\0';
                    pthread_cond_broadcast(&g_ipcCond);
                }
                pthread_mutex_unlock(&g_ipcLock);
            }
        }
        close(cfd);
    }
    return NULL;
}

void tapcore_core_start_ipc(void) {
    pthread_t th;
    pthread_create(&th, NULL, ipc_server_thread, NULL);
    pthread_detach(th);
}

static BOOL dispatchTweakCommand(const char *op, const char *utf8, size_t len, int timeoutMs) {
    pthread_mutex_lock(&g_ipcLock);
    uint64_t seq = ++g_ipcSeq;
    strncpy(g_ipcOp, op, sizeof(g_ipcOp) - 1);
    g_ipcOp[sizeof(g_ipcOp) - 1] = '\0';
    free(g_ipcPayload);
    g_ipcPayload = (char *)malloc(len + 1);
    if (g_ipcPayload) {
        if (len > 0) memcpy(g_ipcPayload, utf8, len);
        g_ipcPayload[len] = '\0';
        g_ipcPayloadLen = len;
    } else {
        g_ipcPayloadLen = 0;
    }
    pthread_mutex_unlock(&g_ipcLock);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(TAPCORE_NOTIFY_CMD),
        NULL, NULL, true);

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec  += timeoutMs / 1000;
    ts.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    BOOL acked = NO;
    pthread_mutex_lock(&g_ipcLock);
    while (g_ipcAckSeq < seq) {
        int r = pthread_cond_timedwait(&g_ipcCond, &g_ipcLock, &ts);
        if (r == ETIMEDOUT) break;
    }
    acked = (g_ipcAckSeq >= seq);
    pthread_mutex_unlock(&g_ipcLock);
    return acked;
}

// ---------------- HID Touch & Keyboard ----------------
static void sendTouchEvent(uint32_t fingerID, double px, double py, int phase) {
    IOHIDFloat nx = px / (double)g_screenW;
    IOHIDFloat ny = py / (double)g_screenH;
    uint64_t ts = mach_absolute_time();

    uint32_t mask = (phase == 0) ? (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition)
                  : (phase == 1) ? kIOHIDDigitizerEventPosition
                                 : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
    Boolean range = (phase != 2), touch = (phase != 2);
    IOHIDFloat pressure = (phase != 2) ? 1.0 : 0.0;

    IOHIDEventRef parent = p_IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand,
        0, 0, mask, 0, nx, ny, 0.0, pressure, 0.0, range, touch, 0);
    IOHIDEventRef child = p_IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, fingerID, fingerID, mask,
        nx, ny, 0.0, pressure, 0.0, range, touch, 0);

    p_IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    p_IOHIDEventSetIntegerValue(child, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    p_IOHIDEventAppendEvent(parent, child, 0);
    p_IOHIDEventSetSenderID(parent, g_senderID);
    p_IOHIDEventSystemClientDispatchEvent(g_hidClient, parent);

    CFRelease(child);
    CFRelease(parent);
}

static void sendHIDKey(uint32_t usagePage, uint32_t usage, Boolean down) {
    IOHIDEventRef ev = p_IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, mach_absolute_time(), usagePage, usage, down, 0);
    if (g_senderID) p_IOHIDEventSetSenderID(ev, g_senderID);
    p_IOHIDEventSystemClientDispatchEvent(g_hidClient, ev);
    CFRelease(ev);
}

static BOOL asciiToHID(char c, uint32_t *outUsage, BOOL *outShift) {
    *outShift = NO;
    if (c >= 'a' && c <= 'z') { *outUsage = 0x04 + (uint32_t)(c - 'a'); return YES; }
    if (c >= 'A' && c <= 'Z') { *outUsage = 0x04 + (uint32_t)(c - 'A'); *outShift = YES; return YES; }
    if (c >= '1' && c <= '9') { *outUsage = 0x1E + (uint32_t)(c - '1'); return YES; }
    if (c == '0') { *outUsage = 0x27; return YES; }
    switch (c) {
        case '\n': case '\r': *outUsage = 0x28; return YES;
        case '\t': *outUsage = 0x2B; return YES;
        case '\b': *outUsage = 0x2A; return YES;
        case ' ':  *outUsage = 0x2C; return YES;
        case '-':  *outUsage = 0x2D; return YES;
        case '_':  *outUsage = 0x2D; *outShift = YES; return YES;
        case '=':  *outUsage = 0x2E; return YES;
        case '+':  *outUsage = 0x2E; *outShift = YES; return YES;
        case '[':  *outUsage = 0x2F; return YES;
        case '{':  *outUsage = 0x2F; *outShift = YES; return YES;
        case ']':  *outUsage = 0x30; return YES;
        case '}':  *outUsage = 0x30; *outShift = YES; return YES;
        case '\\': *outUsage = 0x31; return YES;
        case '|':  *outUsage = 0x31; *outShift = YES; return YES;
        case ';':  *outUsage = 0x33; return YES;
        case ':':  *outUsage = 0x33; *outShift = YES; return YES;
        case '\'': *outUsage = 0x34; return YES;
        case '"':  *outUsage = 0x34; *outShift = YES; return YES;
        case '`':  *outUsage = 0x35; return YES;
        case '~':  *outUsage = 0x35; *outShift = YES; return YES;
        case ',':  *outUsage = 0x36; return YES;
        case '<':  *outUsage = 0x36; *outShift = YES; return YES;
        case '.':  *outUsage = 0x37; return YES;
        case '>':  *outUsage = 0x37; *outShift = YES; return YES;
        case '/':  *outUsage = 0x38; return YES;
        case '?':  *outUsage = 0x38; *outShift = YES; return YES;
        case '!':  *outUsage = 0x1E; *outShift = YES; return YES;
        case '@':  *outUsage = 0x1F; *outShift = YES; return YES;
        case '#':  *outUsage = 0x20; *outShift = YES; return YES;
        case '$':  *outUsage = 0x21; *outShift = YES; return YES;
        case '%':  *outUsage = 0x22; *outShift = YES; return YES;
        case '^':  *outUsage = 0x23; *outShift = YES; return YES;
        case '&':  *outUsage = 0x24; *outShift = YES; return YES;
        case '*':  *outUsage = 0x25; *outShift = YES; return YES;
        case '(':  *outUsage = 0x26; *outShift = YES; return YES;
        case ')':  *outUsage = 0x27; *outShift = YES; return YES;
        default: return NO;
    }
}

static void typeASCII(const char *str, size_t len) {
    for (size_t i = 0; i < len; i++) {
        uint32_t usage = 0; BOOL shift = NO;
        if (!asciiToHID(str[i], &usage, &shift)) continue;
        if (shift) { sendHIDKey(0x07, 0xE1, true); usleep(6000); }
        sendHIDKey(0x07, usage, true);  usleep(10000);
        sendHIDKey(0x07, usage, false); usleep(6000);
        if (shift) { sendHIDKey(0x07, 0xE1, false); usleep(6000); }
        usleep(8000);
    }
}

// ---------------- Screen Capture (Reusable IOSurface) ----------------
// Caller MUST hold g_surfaceLock while accessing the returned surface.
static IOSurfaceRef captureScreenLocked(void) {
    if (!p_CARenderServerRenderDisplay) return NULL;
    if (!g_surface) {
        NSDictionary *props = @{
            (__bridge NSString *)kIOSurfaceWidth:           @(g_screenW),
            (__bridge NSString *)kIOSurfaceHeight:          @(g_screenH),
            (__bridge NSString *)kIOSurfaceBytesPerElement: @(4),
            (__bridge NSString *)kIOSurfacePixelFormat:     @(0x42475241), // 'BGRA'
        };
        g_surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!g_surface) return NULL;
    }
    p_CARenderServerRenderDisplay(0, CFSTR("LCD"), g_surface, 0, 0);
    return g_surface;
}

static inline uint32_t readBGRAtoRGB(const uint8_t *base, size_t bpr, int w, int h, int x, int y) {
    if (x < 0) x = 0; if (x >= w) x = w - 1;
    if (y < 0) y = 0; if (y >= h) y = h - 1;
    const uint8_t *p = base + (size_t)y * bpr + (size_t)x * 4;
    return ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[0];
}

// ---------------- Lua Native Bindings ----------------
static int l_touchDown(lua_State *L) {
    int id = (int)luaL_checkinteger(L, 1);
    double x = luaL_checknumber(L, 2);
    double y = luaL_checknumber(L, 3);
    uint32_t fid = (id >= 0) ? (uint32_t)(id + 1) : 1;
    sendTouchEvent(fid, x, y, 0);
    return 0;
}

static int l_touchMove(lua_State *L) {
    int id = (int)luaL_checkinteger(L, 1);
    double x = luaL_checknumber(L, 2);
    double y = luaL_checknumber(L, 3);
    uint32_t fid = (id >= 0) ? (uint32_t)(id + 1) : 1;
    sendTouchEvent(fid, x, y, 1);
    return 0;
}

static int l_touchUp(lua_State *L) {
    int id = (int)luaL_checkinteger(L, 1);
    double x = luaL_checknumber(L, 2);
    double y = luaL_checknumber(L, 3);
    uint32_t fid = (id >= 0) ? (uint32_t)(id + 1) : 1;
    sendTouchEvent(fid, x, y, 2);
    return 0;
}

static int l_usleep(lua_State *L) {
    double us = luaL_checknumber(L, 1);
    if (us > 0) {
        if (us > 60000000.0) us = 60000000.0;
        int64_t rem = (int64_t)llround(us);
        while (rem > 0) {
            if (tapcore_script_should_stop()) return luaL_error(L, "__TAPCORE_STOPPED__");
            useconds_t step = (rem > 25000) ? 25000 : (useconds_t)rem;
            usleep(step);
            rem -= (int64_t)step;
        }
    }
    return 0;
}

static void keyTypeToHID(int kt, uint32_t *page, uint32_t *usage) {
    *page = 0x0C;
    switch (kt) {
        case TAPCORE_KEY_HOME:        *usage = 0x40; break;
        case TAPCORE_KEY_VOLUME_DOWN: *usage = 0xEA; break;
        case TAPCORE_KEY_VOLUME_UP:   *usage = 0xE9; break;
        case TAPCORE_KEY_POWER:       *usage = 0x30; break;
        default:                    *usage = 0x40; break;
    }
}

static double g_lastKeyDownUs = 0;

static int l_keyDown(lua_State *L) {
    int kt = (int)luaL_checkinteger(L, 1);
    uint32_t page = 0, usage = 0;
    keyTypeToHID(kt, &page, &usage);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    g_lastKeyDownUs = (double)tv.tv_sec * 1e6 + (double)tv.tv_usec;
    sendHIDKey(page, usage, true);
    return 0;
}

static int l_keyUp(lua_State *L) {
    int kt = (int)luaL_checkinteger(L, 1);
    uint32_t page = 0, usage = 0;
    keyTypeToHID(kt, &page, &usage);
    // Ensure a minimum 20ms press duration so SpringBoard registers back-to-back keyDown/keyUp (e.g. double-Home)
    if (g_lastKeyDownUs > 0) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        double elapsed = ((double)tv.tv_sec * 1e6 + (double)tv.tv_usec) - g_lastKeyDownUs;
        if (elapsed >= 0 && elapsed < 20000.0) {
            usleep((useconds_t)(20000.0 - elapsed));
        }
        g_lastKeyDownUs = 0;
    }
    sendHIDKey(page, usage, false);
    return 0;
}

static BOOL isPureASCII(const char *str, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if ((unsigned char)str[i] >= 0x80) return NO;
    }
    return YES;
}

static int l_inputText(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    // Pure ASCII: always type directly via hardware IOKit HID keyboard (100% reliable across all apps, Password fields, WebViews, Spotlight)
    if (isPureASCII(s, len)) {
        tapcore_log("INP", "inputText(%zu) via HID keyboard", len);
        typeASCII(s, len);
        usleep(30000);
        return 0;
    }
    // Non-ASCII (Unicode/emoji): deliver via TapCoreInput.dylib UIKeyInput firstResponder
    if (dispatchTweakCommand("input", s, len, 320)) {
        tapcore_log("INP", "inputText(%zu) Unicode via tweak [%s]", len, g_ipcAckInfo);
        return 0;
    }
    tapcore_log("INP", "inputText(%zu) Unicode tweak no-ack -> ASCII fallback", len);
    typeASCII(s, len);
    return 0;
}

static int l_copyText(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    BOOL ok = dispatchTweakCommand("copy", s, len, 350);
    if (!ok) {
        fprintf(stderr, "[tapcore] copyText: no active UIKit app ACKed (app in background or SpringBoard)\n");
    }
    return 0;
}

static int l_getColor(lua_State *L) {
    int x = (int)llround(luaL_checknumber(L, 1));
    int y = (int)llround(luaL_checknumber(L, 2));
    pthread_mutex_lock(&g_surfaceLock);
    IOSurfaceRef surf = captureScreenLocked();
    if (!surf) {
        pthread_mutex_unlock(&g_surfaceLock);
        return luaL_error(L, "Screen capture failed");
    }
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    int w = (int)IOSurfaceGetWidth(surf);
    int h = (int)IOSurfaceGetHeight(surf);
    uint32_t rgb = readBGRAtoRGB(base, bpr, w, h, x, y);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&g_surfaceLock);

    lua_pushinteger(L, (lua_Integer)rgb);
    return 1;
}

static int l_getColors(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer n = luaL_len(L, 1);

    pthread_mutex_lock(&g_surfaceLock);
    IOSurfaceRef surf = captureScreenLocked();
    if (!surf) {
        pthread_mutex_unlock(&g_surfaceLock);
        return luaL_error(L, "Screen capture failed");
    }
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    int w = (int)IOSurfaceGetWidth(surf);
    int h = (int)IOSurfaceGetHeight(surf);

    lua_createtable(L, (int)n, 0);
    for (lua_Integer i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, i);
        int x = 0, y = 0;
        if (lua_istable(L, -1)) {
            lua_rawgeti(L, -1, 1); x = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
            lua_rawgeti(L, -1, 2); y = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        }
        lua_pop(L, 1);
        uint32_t rgb = readBGRAtoRGB(base, bpr, w, h, x, y);
        lua_pushinteger(L, (lua_Integer)rgb);
        lua_rawseti(L, -2, i);
    }
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&g_surfaceLock);
    return 1;
}

typedef struct { uint32_t rgb; int dx; int dy; } ColorPt;

static int l_findColors(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int maxCount = (int)luaL_optinteger(L, 2, 1);
    if (maxCount <= 0) maxCount = 256;
    BOOL hasRegion = lua_istable(L, 3);
    int rx = 0, ry = 0, rw = g_screenW, rh = g_screenH;
    if (hasRegion) {
        lua_rawgeti(L, 3, 1); rx = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        lua_rawgeti(L, 3, 2); ry = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        lua_rawgeti(L, 3, 3); rw = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        lua_rawgeti(L, 3, 4); rh = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
    }
    BOOL rightToLeft = lua_toboolean(L, 5) ? YES : NO;
    BOOL bottomToTop = lua_toboolean(L, 6) ? YES : NO;

    lua_Integer npts = luaL_len(L, 1);
    if (npts <= 0) { lua_newtable(L); return 1; }
    if (npts > 256) npts = 256;
    ColorPt pts[256];
    for (lua_Integer i = 0; i < npts; i++) {
        lua_rawgeti(L, 1, i + 1);
        lua_rawgeti(L, -1, 1); pts[i].rgb = (uint32_t)lua_tointeger(L, -1); lua_pop(L, 1);
        lua_rawgeti(L, -1, 2); pts[i].dx  = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        lua_rawgeti(L, -1, 3); pts[i].dy  = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        lua_pop(L, 1);
    }

    pthread_mutex_lock(&g_surfaceLock);
    IOSurfaceRef surf = captureScreenLocked();
    if (!surf) {
        pthread_mutex_unlock(&g_surfaceLock);
        return luaL_error(L, "Screen capture failed");
    }
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    int w = (int)IOSurfaceGetWidth(surf);
    int h = (int)IOSurfaceGetHeight(surf);

    if (rx < 0) rx = 0;
    if (ry < 0) ry = 0;
    int xEnd = rx + rw; if (xEnd > w) xEnd = w;
    int yEnd = ry + rh; if (yEnd > h) yEnd = h;

    uint32_t c0 = pts[0].rgb;
    uint8_t r0 = (c0 >> 16) & 0xFF, g0 = (c0 >> 8) & 0xFF, b0 = c0 & 0xFF;

    lua_newtable(L);
    int found = 0;

    int yStart = bottomToTop ? (yEnd - 1) : ry;
    int yStop  = bottomToTop ? (ry - 1)   : yEnd;
    int yStep  = bottomToTop ? -1 : 1;

    int xStart = rightToLeft ? (xEnd - 1) : rx;
    int xStop  = rightToLeft ? (rx - 1)   : xEnd;
    int xStep  = rightToLeft ? -1 : 1;

    for (int y = yStart; y != yStop && found < maxCount; y += yStep) {
        const uint8_t *row = base + (size_t)y * bpr;
        for (int x = xStart; x != xStop && found < maxCount; x += xStep) {
            const uint8_t *p = row + (size_t)x * 4;
            if (p[0] != b0 || p[1] != g0 || p[2] != r0) continue;

            BOOL match = YES;
            for (lua_Integer k = 1; k < npts; k++) {
                int px = x + pts[k].dx;
                int py = y + pts[k].dy;
                if (px < 0 || px >= w || py < 0 || py >= h) { match = NO; break; }
                const uint8_t *q = base + (size_t)py * bpr + (size_t)px * 4;
                uint32_t rgb = ((uint32_t)q[2] << 16) | ((uint32_t)q[1] << 8) | (uint32_t)q[0];
                if (rgb != pts[k].rgb) { match = NO; break; }
            }
            if (match) {
                found++;
                lua_createtable(L, 2, 0);
                lua_pushinteger(L, x); lua_rawseti(L, -2, 1);
                lua_pushinteger(L, y); lua_rawseti(L, -2, 2);
                lua_rawseti(L, -2, found);
            }
        }
    }

    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&g_surfaceLock);
    return 1;
}

// ---------------- Vision OCR engine ----------------
// 1. Under g_surfaceLock: render the screen and copy only the requested region (optionally
//    downscaled) into a private, reused pixel buffer (a few ms).
// 2. Release g_surfaceLock, then run Vision on the private copy, so getColor / findColors /
//    web capture never wait for OCR.
// Requests are cached per recognition level; g_ocrLock serializes OCR calls.

typedef struct {
    BOOL hasRegion;
    int rx, ry, rw, rh;      // requested region in screen pixels
    BOOL fast;               // VNRequestTextRecognitionLevelFast instead of Accurate
    BOOL correct;            // language correction
    int div;                 // 1 = native resolution, 2 = half, 3 = third
    double minTextHeight;    // fraction of the image height, 0 = Vision default
} TCOcrParams;

typedef struct {
    int screenW, screenH;
    double captureMs, visionMs;
} TCOcrStats;

static pthread_mutex_t g_ocrLock = PTHREAD_MUTEX_INITIALIZER;
static VNRecognizeTextRequest *g_ocrReqFast = nil;
static VNRecognizeTextRequest *g_ocrReqAccurate = nil;
static CVPixelBufferRef g_ocrBuf = NULL;

static double msSince(const struct timeval *t0) {
    struct timeval t1;
    gettimeofday(&t1, NULL);
    return (t1.tv_sec - t0->tv_sec) * 1000.0 + (t1.tv_usec - t0->tv_usec) / 1000.0;
}

// Caller holds g_ocrLock.
static CVPixelBufferRef ocrBufferOfSize(size_t w, size_t h) {
    if (g_ocrBuf && CVPixelBufferGetWidth(g_ocrBuf) == w && CVPixelBufferGetHeight(g_ocrBuf) == h) {
        return g_ocrBuf;
    }
    if (g_ocrBuf) {
        CVPixelBufferRelease(g_ocrBuf);
        g_ocrBuf = NULL;
    }
    NSDictionary *attrs = @{ (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &g_ocrBuf);
    return g_ocrBuf;
}

// Caller holds g_ocrLock. Copies the clamped region into the private buffer.
// Writes the region actually covered (screen pixels) back into p.
static CVPixelBufferRef ocrSnapshot(TCOcrParams *p, TCOcrStats *st) {
    pthread_mutex_lock(&g_surfaceLock);
    IOSurfaceRef surf = captureScreenLocked();
    if (!surf) {
        pthread_mutex_unlock(&g_surfaceLock);
        return NULL;
    }
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    int sw = (int)IOSurfaceGetWidth(surf);
    int sh = (int)IOSurfaceGetHeight(surf);
    st->screenW = sw;
    st->screenH = sh;

    int rx = 0, ry = 0, rw = sw, rh = sh;
    if (p->hasRegion) {
        rx = p->rx < 0 ? 0 : p->rx;
        ry = p->ry < 0 ? 0 : p->ry;
        rw = p->rw;
        rh = p->rh;
        if (rx + rw > sw) rw = sw - rx;
        if (ry + rh > sh) rh = sh - ry;
    }
    int div = p->div < 1 ? 1 : (p->div > 3 ? 3 : p->div);
    int ow = rw / div, oh = rh / div;
    if (ow < 8 || oh < 8) {               // too small to downscale: use native pixels
        div = 1;
        ow = rw;
        oh = rh;
    }
    CVPixelBufferRef pb = (ow > 1 && oh > 1) ? ocrBufferOfSize((size_t)ow, (size_t)oh) : NULL;
    if (pb) {
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t dbpr = CVPixelBufferGetBytesPerRow(pb);
        const uint8_t *src = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
        size_t sbpr = IOSurfaceGetBytesPerRow(surf);
        if (div == 1) {
            for (int y = 0; y < oh; y++) {
                memcpy(dst + (size_t)y * dbpr, src + (size_t)(ry + y) * sbpr + (size_t)rx * 4, (size_t)ow * 4);
            }
        } else {
            // Box filter: average div x div source pixels per output pixel (keeps text edges readable).
            int n = div * div;
            for (int y = 0; y < oh; y++) {
                uint8_t *drow = dst + (size_t)y * dbpr;
                for (int x = 0; x < ow; x++) {
                    unsigned b = 0, g = 0, r = 0;
                    for (int dy = 0; dy < div; dy++) {
                        const uint8_t *s = src + (size_t)(ry + y * div + dy) * sbpr + (size_t)(rx + x * div) * 4;
                        for (int dx = 0; dx < div; dx++, s += 4) {
                            b += s[0]; g += s[1]; r += s[2];
                        }
                    }
                    uint8_t *d = drow + (size_t)x * 4;
                    d[0] = (uint8_t)(b / n); d[1] = (uint8_t)(g / n); d[2] = (uint8_t)(r / n); d[3] = 255;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&g_surfaceLock);

    p->rx = rx; p->ry = ry;
    p->rw = ow * div; p->rh = oh * div;   // area really covered by the buffer
    return pb;
}

// Runs OCR and returns @[@{text, x, y, w, h, confidence}] in screen pixels (top-left origin),
// or nil with *errOut set.
static NSArray<NSDictionary *> *tapcoreRunOCR(TCOcrParams p, NSArray<NSString *> *langs,
                                              TCOcrStats *st, NSString **errOut) {
    @autoreleasepool {
        memset(st, 0, sizeof(*st));
        pthread_mutex_lock(&g_ocrLock);

        struct timeval t0;
        gettimeofday(&t0, NULL);
        CVPixelBufferRef pb = ocrSnapshot(&p, st);
        st->captureMs = msSince(&t0);
        if (!pb) {
            pthread_mutex_unlock(&g_ocrLock);
            if (p.rw <= 1 || p.rh <= 1) return @[];
            if (errOut) *errOut = @"Screen capture failed";
            return nil;
        }

        VNRecognizeTextRequest *req = p.fast ? g_ocrReqFast : g_ocrReqAccurate;
        if (!req) {
            req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
            req.recognitionLevel = p.fast ? VNRequestTextRecognitionLevelFast
                                          : VNRequestTextRecognitionLevelAccurate;
            if (p.fast) g_ocrReqFast = req; else g_ocrReqAccurate = req;
        }
        req.usesLanguageCorrection = p.correct;
        req.recognitionLanguages = langs.count ? langs : @[@"en-US"];
        req.minimumTextHeight = (float)(p.minTextHeight > 0 && p.minTextHeight < 1 ? p.minTextHeight : 0);

        gettimeofday(&t0, NULL);
        NSError *err = nil;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
        BOOL ok = [handler performRequests:@[req] error:&err];
        st->visionMs = msSince(&t0);

        NSMutableArray<NSDictionary *> *items = nil;
        if (ok && !err) {
            items = [NSMutableArray arrayWithCapacity:req.results.count];
            double ox = p.rx, oy = p.ry, cw = p.rw, ch = p.rh;
            for (VNRecognizedTextObservation *obs in req.results) {
                VNRecognizedText *top = [obs topCandidates:1].firstObject;
                if (!top) continue;
                CGRect b = obs.boundingBox;   // normalized, bottom-left origin
                [items addObject:@{
                    @"text": top.string ?: @"",
                    @"x": @(ox + b.origin.x * cw),
                    @"y": @(oy + (1.0 - (b.origin.y + b.size.height)) * ch),
                    @"w": @(b.size.width * cw),
                    @"h": @(b.size.height * ch),
                    @"confidence": @(top.confidence)
                }];
            }
        } else if (errOut) {
            *errOut = err ? err.localizedDescription : @"Vision OCR failed";
        }
        pthread_mutex_unlock(&g_ocrLock);
        return items;
    }
}

static int luaOptInt(lua_State *L, int tbl, const char *key, int def) {
    lua_getfield(L, tbl, key);
    int v = lua_isnumber(L, -1) ? (int)llround(lua_tonumber(L, -1)) : def;
    lua_pop(L, 1);
    return v;
}

// ocr({level = "fast"|"accurate", correct = bool, languages = {...}, region = {x,y,w,h},
//      scale = 1|0.5|0.33, minTextHeight = 0..1})
static int l_ocr(lua_State *L) {
    TCOcrParams p = { .hasRegion = NO, .fast = NO, .correct = YES, .div = 1, .minTextHeight = 0 };
    NSMutableArray<NSString *> *langs = [NSMutableArray array];

    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "level");
        if (lua_isstring(L, -1)) p.fast = (strcmp(lua_tostring(L, -1), "fast") == 0);
        lua_pop(L, 1);

        lua_getfield(L, 1, "correct");
        if (lua_isboolean(L, -1)) p.correct = lua_toboolean(L, -1) ? YES : NO;
        else if (p.fast) p.correct = NO;
        lua_pop(L, 1);

        lua_getfield(L, 1, "scale");
        if (lua_isnumber(L, -1)) {
            double s = lua_tonumber(L, -1);
            if (s > 0 && s < 1) p.div = (int)llround(1.0 / s);
        }
        lua_pop(L, 1);

        lua_getfield(L, 1, "minTextHeight");
        if (lua_isnumber(L, -1)) p.minTextHeight = lua_tonumber(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, 1, "languages");
        if (lua_istable(L, -1)) {
            lua_Integer nl = luaL_len(L, -1);
            for (lua_Integer i = 1; i <= nl; i++) {
                lua_rawgeti(L, -1, i);
                if (lua_isstring(L, -1)) {
                    NSString *ls = [NSString stringWithUTF8String:lua_tostring(L, -1)];
                    if (ls) [langs addObject:ls];
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 1, "region");
        if (lua_istable(L, -1)) {
            int t = lua_gettop(L);
            lua_rawgeti(L, t, 1);
            if (lua_isnumber(L, -1)) {         // {x, y, w, h}
                lua_pop(L, 1);
                lua_rawgeti(L, t, 1); p.rx = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
                lua_rawgeti(L, t, 2); p.ry = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
                lua_rawgeti(L, t, 3); p.rw = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
                lua_rawgeti(L, t, 4); p.rh = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
            } else {                           // {x =, y =, width =, height =}
                lua_pop(L, 1);
                p.rx = luaOptInt(L, t, "x", 0);
                p.ry = luaOptInt(L, t, "y", 0);
                p.rw = luaOptInt(L, t, "width", 0);
                p.rh = luaOptInt(L, t, "height", 0);
            }
            p.hasRegion = (p.rw > 1 && p.rh > 1);
            if (!p.hasRegion) {
                lua_pop(L, 1);
                lua_newtable(L);
                return 1;
            }
        }
        lua_pop(L, 1);
    }

    TCOcrStats st;
    NSString *err = nil;
    NSArray<NSDictionary *> *items = tapcoreRunOCR(p, langs, &st, &err);
    if (!items) {
        return luaL_error(L, "Vision OCR failed: %s", err ? err.UTF8String : "unknown");
    }

    lua_createtable(L, (int)items.count, 0);
    int idx = 0;
    for (NSDictionary *it in items) {
        double x = [it[@"x"] doubleValue], y = [it[@"y"] doubleValue];
        double x2 = x + [it[@"w"] doubleValue], y2 = y + [it[@"h"] doubleValue];

        lua_createtable(L, 0, 3);
        NSData *td = [(NSString *)it[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
        lua_pushlstring(L, (td && td.bytes) ? (const char *)td.bytes : "", td ? td.length : 0);
        lua_setfield(L, -2, "text");
        lua_pushnumber(L, [it[@"confidence"] doubleValue]);
        lua_setfield(L, -2, "confidence");

        lua_createtable(L, 0, 4);
        const struct { const char *name; double px, py; } corners[4] = {
            {"topLeft", x, y}, {"topRight", x2, y}, {"bottomLeft", x, y2}, {"bottomRight", x2, y2}
        };
        for (int c = 0; c < 4; c++) {
            lua_createtable(L, 0, 2);
            lua_pushnumber(L, corners[c].px); lua_setfield(L, -2, "x");
            lua_pushnumber(L, corners[c].py); lua_setfield(L, -2, "y");
            lua_setfield(L, -2, corners[c].name);
        }
        lua_setfield(L, -2, "rectangle");
        lua_rawseti(L, -2, ++idx);
    }
    return 1;
}

// ---------------- Template Matching (findImage) ----------------
static uint8_t *loadImageBGRA(const char *path, int *outW, int *outH) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;

    int w = (int)CGImageGetWidth(img);
    int h = (int)CGImageGetHeight(img);
    if (w <= 0 || h <= 0) { CGImageRelease(img); return NULL; }

    size_t bpr = (size_t)w * 4;
    uint8_t *buf = (uint8_t *)calloc(1, bpr * (size_t)h);
    if (!buf) { CGImageRelease(img); return NULL; }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        buf, (size_t)w, (size_t)h, 8, bpr, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CGImageRelease(img);

    *outW = w;
    *outH = h;
    return buf;
}

static double computeNCC(const uint8_t *screen, size_t sbpr,
                         const uint8_t *tmpl, int tw, int th, int sx, int sy) {
    double sumS = 0, sumT = 0, sumS2 = 0, sumT2 = 0, sumST = 0;
    int count = 0;
    int step = (tw * th > 4000) ? 2 : 1;
    for (int ty = 0; ty < th; ty += step) {
        const uint8_t *srow = screen + (size_t)(sy + ty) * sbpr + (size_t)sx * 4;
        const uint8_t *trow = tmpl + (size_t)ty * (size_t)tw * 4;
        for (int tx = 0; tx < tw; tx += step) {
            const uint8_t *tp = trow + (size_t)tx * 4;
            if (tp[3] < 128) continue;
            const uint8_t *sp = srow + (size_t)tx * 4;
            // Luminance + color check via RGB channels
            for (int c = 0; c < 3; c++) {
                double sv = (double)sp[c];
                double tv = (double)tp[c];
                sumS  += sv;
                sumT  += tv;
                sumS2 += sv * sv;
                sumT2 += tv * tv;
                sumST += sv * tv;
                count++;
            }
        }
    }
    if (count == 0) return 0.0;
    double meanS = sumS / count;
    double meanT = sumT / count;
    double varS = sumS2 - count * meanS * meanS;
    double varT = sumT2 - count * meanT * meanT;
    double cov  = sumST - count * meanS * meanT;
    if (varS < 1e-3 && varT < 1e-3) {
        // Both flat solid colors -> compare color similarity
        double diff = fabs(meanS - meanT) / 255.0;
        return 1.0 - diff;
    }
    if (varS < 1e-3 || varT < 1e-3) return 0.0;
    return cov / sqrt(varS * varT);
}

static int l_findImage(lua_State *L) {
    @autoreleasepool {
        const char *path = luaL_checkstring(L, 1);
        int maxCount = (int)luaL_optinteger(L, 2, 1);
        if (maxCount <= 0) maxCount = 1;
        double threshold = luaL_optnumber(L, 3, 0.9);
        BOOL hasRegion = lua_istable(L, 4);
        int rx = 0, ry = 0, rw = g_screenW, rh = g_screenH;
        if (hasRegion) {
            lua_rawgeti(L, 4, 1); rx = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
            lua_rawgeti(L, 4, 2); ry = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
            lua_rawgeti(L, 4, 3); rw = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
            lua_rawgeti(L, 4, 4); rh = (int)llround(lua_tonumber(L, -1)); lua_pop(L, 1);
        }

        int tw = 0, th = 0;
        uint8_t *tmpl = loadImageBGRA(path, &tw, &th);
        if (!tmpl) {
            lua_newtable(L);
            return 1;
        }

        // Sample up to 16 evenly spaced opaque points for ultra-fast pre-filtering
        int spx[16], spy[16];
        uint8_t spb[16], spg[16], spr[16];
        int nsp = 0;
        for (int gy = 0; gy < 4 && nsp < 16; gy++) {
            for (int gx = 0; gx < 4 && nsp < 16; gx++) {
                int x = (tw * (gx * 2 + 1)) / 8;
                int y = (th * (gy * 2 + 1)) / 8;
                if (x >= tw) x = tw - 1;
                if (y >= th) y = th - 1;
                const uint8_t *tp = tmpl + ((size_t)y * (size_t)tw + (size_t)x) * 4;
                if (tp[3] >= 128) {
                    spx[nsp] = x; spy[nsp] = y;
                    spb[nsp] = tp[0]; spg[nsp] = tp[1]; spr[nsp] = tp[2];
                    nsp++;
                }
            }
        }

        pthread_mutex_lock(&g_surfaceLock);
        IOSurfaceRef surf = captureScreenLocked();
        if (!surf) {
            pthread_mutex_unlock(&g_surfaceLock);
            free(tmpl);
            return luaL_error(L, "Screen capture failed");
        }
        IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
        const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
        size_t bpr = IOSurfaceGetBytesPerRow(surf);
        int sw = (int)IOSurfaceGetWidth(surf);
        int sh = (int)IOSurfaceGetHeight(surf);

        if (rx < 0) rx = 0;
        if (ry < 0) ry = 0;
        int maxX = rx + rw - tw; if (maxX > sw - tw) maxX = sw - tw;
        int maxY = ry + rh - th; if (maxY > sh - th) maxY = sh - th;

        int maxSadPerCh = (int)((1.0 - threshold) * 255.0 * 3.0) + 28;
        if (maxSadPerCh < 25) maxSadPerCh = 25;
        int sadLimit = maxSadPerCh * (nsp > 0 ? nsp : 1) * 3;

        double bestScore = -1.0;
        int bestX = -1, bestY = -1;
        int stride = (tw >= 20 && th >= 20) ? 2 : 1;

        for (int y = ry; y <= maxY; y += stride) {
            for (int x = rx; x <= maxX; x += stride) {
                int sad = 0;
                for (int i = 0; i < nsp; i++) {
                    const uint8_t *sp = base + (size_t)(y + spy[i]) * bpr + (size_t)(x + spx[i]) * 4;
                    sad += abs((int)sp[0] - (int)spb[i])
                         + abs((int)sp[1] - (int)spg[i])
                         + abs((int)sp[2] - (int)spr[i]);
                    if (sad > sadLimit) break;
                }
                if (sad > sadLimit) continue;

                // Refine locally around (x, y)
                int y0 = (y - stride < ry) ? ry : (y - stride);
                int y1 = (y + stride > maxY) ? maxY : (y + stride);
                int x0 = (x - stride < rx) ? rx : (x - stride);
                int x1 = (x + stride > maxX) ? maxX : (x + stride);
                for (int fy = y0; fy <= y1; fy++) {
                    for (int fx = x0; fx <= x1; fx++) {
                        double sc = computeNCC(base, bpr, tmpl, tw, th, fx, fy);
                        if (sc > bestScore) {
                            bestScore = sc;
                            bestX = fx;
                            bestY = fy;
                        }
                    }
                }
                if (bestScore >= threshold && maxCount == 1) break;
            }
            if (bestScore >= threshold && maxCount == 1) break;
        }

        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
        pthread_mutex_unlock(&g_surfaceLock);
        free(tmpl);

        lua_newtable(L);
        if (bestScore >= threshold && bestX >= 0 && bestY >= 0) {
            lua_createtable(L, 2, 0);
            lua_pushnumber(L, bestX + tw / 2.0); lua_rawseti(L, -2, 1);
            lua_pushnumber(L, bestY + th / 2.0); lua_rawseti(L, -2, 2);
            lua_rawseti(L, -2, 1);
        }
        return 1;
    }
}

// ---------------- System / Shell / URL / AppKill / Photos ----------------
static const char *resolveShell(void) {
    if (access("/var/jb/bin/sh", X_OK) == 0) return "/var/jb/bin/sh";
    if (access("/var/jb/usr/bin/sh", X_OK) == 0) return "/var/jb/usr/bin/sh";
    return "/bin/sh";
}

// Replacement for unavailable C system() on iOS SDK (used by Lua loslib.c)
int tapcore_ios_system(const char *cmd) {
    if (!cmd) return 1;
    const char *sh = resolveShell();
    pid_t pid = fork();
    if (pid == 0) {
        setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
        execl(sh, "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    return status;
}

static int l_execute(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    const char *sh = resolveShell();

    int fds[2];
    if (pipe(fds) != 0) {
        lua_pushstring(L, "");
        return 1;
    }

    pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);
        setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
        execl(sh, "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    if (pid < 0) {
        close(fds[0]);
        lua_pushstring(L, "");
        return 1;
    }

    luaL_Buffer b;
    luaL_buffinit(L, &b);
    char chunk[4096];
    ssize_t n;
    while ((n = read(fds[0], chunk, sizeof(chunk))) > 0) {
        luaL_addlstring(&b, chunk, (size_t)n);
    }
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    luaL_pushresult(&b);
    return 1;
}

static int l_openURL(lua_State *L) {
    const char *urlStr = luaL_checkstring(L, 1);
    @autoreleasepool {
        BOOL opened = NO;
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        if (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)]) {
            id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace));
            NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlStr]];
            if (ws && url) {
                SEL sel = NSSelectorFromString(@"openSensitiveURL:withOptions:");
                if ([ws respondsToSelector:sel]) {
                    opened = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sel, url, nil);
                }
                if (!opened) {
                    SEL sel2 = NSSelectorFromString(@"openURL:");
                    if ([ws respondsToSelector:sel2]) {
                        opened = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel2, url);
                    }
                }
            }
        }
        if (!opened) {
            pid_t pid = fork();
            if (pid == 0) {
                execl("/var/jb/usr/bin/uiopen", "uiopen", "--url", urlStr, (char *)NULL);
                _exit(127);
            } else if (pid > 0) {
                int st = 0;
                waitpid(pid, &st, 0);
            }
        }
    }
    return 0;
}

static int l_rootDir(lua_State *L) {
    @autoreleasepool {
        NSString *dir = tapcore_scripts_dir();
        lua_pushstring(L, dir.UTF8String);
    }
    return 1;
}

static int l_appKill(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    @autoreleasepool {
        if (p_BKSTerminateApplicationForReasonAndReportWithDescription) {
            CFStringRef cfBid = CFStringCreateWithCString(kCFAllocatorDefault, bid, kCFStringEncodingUTF8);
            if (cfBid) {
                p_BKSTerminateApplicationForReasonAndReportWithDescription(cfBid, 5, false, CFSTR("tapcore appKill"));
                CFRelease(cfBid);
            }
        }
        // Reliable fallback: resolve executable name via LSApplicationProxy and killall -9
        NSString *nsBid = [NSString stringWithUTF8String:bid];
        NSString *execName = nil;
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        if (proxyCls && [proxyCls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, @selector(applicationProxyForIdentifier:), nsBid);
            if (proxy) {
                NSURL *bundleURL = nil;
                SEL urlSel = NSSelectorFromString(@"bundleURL");
                if ([proxy respondsToSelector:urlSel]) {
                    bundleURL = ((id (*)(id, SEL))objc_msgSend)(proxy, urlSel);
                }
                if (bundleURL) {
                    NSBundle *b = [NSBundle bundleWithURL:bundleURL];
                    execName = [b objectForInfoDictionaryKey:@"CFBundleExecutable"];
                }
            }
        }
        if (execName.length > 0) {
            pid_t pid = fork();
            if (pid == 0) {
                const char *ka = (access("/var/jb/usr/bin/killall", X_OK) == 0)
                    ? "/var/jb/usr/bin/killall" : "/usr/bin/killall";
                execl(ka, "killall", "-9", execName.UTF8String, (char *)NULL);
                _exit(127);
            } else if (pid > 0) {
                int st = 0;
                waitpid(pid, &st, 0);
            }
        }
    }
    return 0;
}

static int l_saveToSystemAlbum(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    @autoreleasepool {
        NSURL *fileURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            return luaL_error(L, "File does not exist: %s", path);
        }
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL success = NO;
        __block NSString *errMsg = nil;

        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL];
        } completionHandler:^(BOOL ok, NSError *error) {
            success = ok;
            if (error) errMsg = error.localizedDescription;
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        if (!success) {
            return luaL_error(L, "saveToSystemAlbum failed: %s",
                              errMsg ? errMsg.UTF8String : "timeout");
        }
    }
    return 0;
}

static int l_clearSystemAlbum(lua_State *L) {
    (void)L;
    @autoreleasepool {
        PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithOptions:nil];
        if (assets.count == 0) return 0;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest deleteAssets:assets];
        } completionHandler:^(BOOL ok, NSError *error) {
            if (!ok && error) {
                fprintf(stderr, "[tapcore] clearSystemAlbum error: %s\n", error.localizedDescription.UTF8String);
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    }
    return 0;
}

// ---------------- Register the native API into Lua ----------------
void tapcore_core_register_lua(lua_State *L) {
    static const luaL_Reg globals[] = {
        {"touchDown",         l_touchDown},
        {"touchMove",         l_touchMove},
        {"touchUp",           l_touchUp},
        {"usleep",            l_usleep},
        {"keyDown",           l_keyDown},
        {"keyUp",             l_keyUp},
        {"inputText",         l_inputText},
        {"copyText",          l_copyText},
        {"getColor",          l_getColor},
        {"getColors",         l_getColors},
        {"findColors",        l_findColors},
        {"ocr",               l_ocr},
        {"findImage",         l_findImage},
        {"execute",           l_execute},
        {"openURL",           l_openURL},
        {"rootDir",           l_rootDir},
        {"appKill",           l_appKill},
        {"saveToSystemAlbum", l_saveToSystemAlbum},
        {"saveImageToAlbum",  l_saveToSystemAlbum},
        {"saveToAlbum",       l_saveToSystemAlbum},
        {"clearSystemAlbum",  l_clearSystemAlbum},
        {NULL, NULL}
    };
    for (const luaL_Reg *r = globals; r->name; r++) {
        lua_pushcfunction(L, r->func);
        lua_setglobal(L, r->name);
    }

    // OCR_METHOD table
    lua_newtable(L);
    lua_pushinteger(L, 1); lua_setfield(L, -2, "IOS_VISION");
    lua_setglobal(L, "OCR_METHOD");

    // KEY_TYPE table
    lua_newtable(L);
    lua_pushinteger(L, TAPCORE_KEY_HOME);        lua_setfield(L, -2, "HOME_BUTTON");
    lua_pushinteger(L, TAPCORE_KEY_HOME);        lua_setfield(L, -2, "MENU_BUTTON");
    lua_pushinteger(L, TAPCORE_KEY_VOLUME_DOWN); lua_setfield(L, -2, "VOLUME_DOWN_BUTTON");
    lua_pushinteger(L, TAPCORE_KEY_VOLUME_UP);   lua_setfield(L, -2, "VOLUME_UP_BUTTON");
    lua_pushinteger(L, TAPCORE_KEY_POWER);       lua_setfield(L, -2, "POWER_BUTTON");
    lua_setglobal(L, "KEY_TYPE");
}

// ---------------- Direct Native Studio APIs (PNG Capture, Crop, OCR, Test) ----------------
static void freeMallocData(void *info, const void *data, size_t size) {
    (void)info; (void)size;
    free((void *)data);
}

NSData *tapcore_capture_png(int *outW, int *outH) {
    @autoreleasepool {
        pthread_mutex_lock(&g_surfaceLock);
        IOSurfaceRef surf = captureScreenLocked();
        if (!surf) {
            pthread_mutex_unlock(&g_surfaceLock);
            return nil;
        }
        IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
        int w = (int)IOSurfaceGetWidth(surf);
        int h = (int)IOSurfaceGetHeight(surf);
        size_t bpr = IOSurfaceGetBytesPerRow(surf);
        size_t sz = bpr * (size_t)h;
        void *copy = malloc(sz);
        if (copy) memcpy(copy, IOSurfaceGetBaseAddress(surf), sz);
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
        pthread_mutex_unlock(&g_surfaceLock);

        if (!copy) return nil;
        if (outW) *outW = w;
        if (outH) *outH = h;

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, copy, sz, freeMallocData);
        CGImageRef img = CGImageCreate(
            (size_t)w, (size_t)h, 8, 32, bpr, cs,
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
            dp, NULL, false, kCGRenderingIntentDefault);

        NSMutableData *png = [NSMutableData data];
        CGImageDestinationRef dst = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
        if (dst && img) {
            CGImageDestinationAddImage(dst, img, NULL);
            CGImageDestinationFinalize(dst);
        }
        if (dst) CFRelease(dst);
        if (img) CGImageRelease(img);
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
        return png.length > 0 ? png : nil;
    }
}

NSData *tapcore_crop_png_data(NSData *pngData, int x, int y, int w, int h) {
    @autoreleasepool {
        if (!pngData || w <= 0 || h <= 0) return nil;
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)pngData, NULL);
        if (!src) return nil;
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!img) return nil;

        int imgW = (int)CGImageGetWidth(img);
        int imgH = (int)CGImageGetHeight(img);
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x + w > imgW) w = imgW - x;
        if (y + h > imgH) h = imgH - y;
        if (w <= 0 || h <= 0) { CGImageRelease(img); return nil; }

        CGImageRef cropped = CGImageCreateWithImageInRect(img, CGRectMake(x, y, w, h));
        CGImageRelease(img);
        if (!cropped) return nil;

        NSMutableData *outPng = [NSMutableData data];
        CGImageDestinationRef dst = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)outPng, CFSTR("public.png"), 1, NULL);
        if (dst) {
            CGImageDestinationAddImage(dst, cropped, NULL);
            CGImageDestinationFinalize(dst);
            CFRelease(dst);
        }
        CGImageRelease(cropped);
        return outPng.length > 0 ? outPng : nil;
    }
}

// REST /api/ocr. opts: region ([x,y,w,h] or {x,y,width,height}), languages, level ("fast"|"accurate"),
// correct (bool), scale (0.5 = half resolution), min_text_height (0..1).
NSDictionary *tapcore_ocr_dict(NSDictionary *opts) {
    @autoreleasepool {
        if (![opts isKindOfClass:[NSDictionary class]]) opts = @{};
        struct timeval t0;
        gettimeofday(&t0, NULL);

        TCOcrParams p = { .hasRegion = NO, .fast = NO, .correct = YES, .div = 1, .minTextHeight = 0 };
        id reg = opts[@"region"];
        if ([reg isKindOfClass:[NSArray class]] && [(NSArray *)reg count] >= 4) {
            NSArray *a = (NSArray *)reg;
            p.rx = [a[0] intValue]; p.ry = [a[1] intValue]; p.rw = [a[2] intValue]; p.rh = [a[3] intValue];
            p.hasRegion = (p.rw > 1 && p.rh > 1);
        } else if ([reg isKindOfClass:[NSDictionary class]]) {
            p.rx = [reg[@"x"] intValue]; p.ry = [reg[@"y"] intValue];
            p.rw = [reg[@"width"] intValue]; p.rh = [reg[@"height"] intValue];
            p.hasRegion = (p.rw > 1 && p.rh > 1);
        }
        if ([opts[@"level"] isKindOfClass:[NSString class]]) p.fast = [opts[@"level"] isEqualToString:@"fast"];
        p.correct = [opts[@"correct"] isKindOfClass:[NSNumber class]] ? [opts[@"correct"] boolValue] : !p.fast;
        if ([opts[@"scale"] isKindOfClass:[NSNumber class]]) {
            double s = [opts[@"scale"] doubleValue];
            if (s > 0 && s < 1) p.div = (int)llround(1.0 / s);
        }
        if ([opts[@"min_text_height"] isKindOfClass:[NSNumber class]]) p.minTextHeight = [opts[@"min_text_height"] doubleValue];
        NSArray *langs = [opts[@"languages"] isKindOfClass:[NSArray class]] ? opts[@"languages"] : @[@"en-US"];

        TCOcrStats st;
        NSString *err = nil;
        NSArray<NSDictionary *> *raw = tapcoreRunOCR(p, langs, &st, &err);
        if (!raw) return @{@"error": err ?: @"OCR failed"};

        NSMutableArray *items = [NSMutableArray arrayWithCapacity:raw.count];
        for (NSDictionary *it in raw) {
            double x = [it[@"x"] doubleValue], y = [it[@"y"] doubleValue];
            double w = [it[@"w"] doubleValue], h = [it[@"h"] doubleValue];
            [items addObject:@{
                @"text": it[@"text"],
                @"x": @(round(x + w / 2.0)),
                @"y": @(round(y + h / 2.0)),
                @"confidence": @(round([it[@"confidence"] doubleValue] * 100.0) / 100.0),
                @"box": @{ @"x": @(round(x)), @"y": @(round(y)), @"width": @(round(w)), @"height": @(round(h)) }
            }];
        }
        return @{
            @"width": @(st.screenW),
            @"height": @(st.screenH),
            @"level": p.fast ? @"fast" : @"accurate",
            @"capture_ms": @(round(st.captureMs * 10.0) / 10.0),
            @"vision_ms": @(round(st.visionMs * 10.0) / 10.0),
            @"elapsed_ms": @(round(msSince(&t0) * 10.0) / 10.0),
            @"items": items
        };
    }
}

uint32_t tapcore_read_pixel(int x, int y) {
    pthread_mutex_lock(&g_surfaceLock);
    IOSurfaceRef surf = captureScreenLocked();
    if (!surf) { pthread_mutex_unlock(&g_surfaceLock); return 0; }
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    uint32_t rgb = readBGRAtoRGB(
        (const uint8_t *)IOSurfaceGetBaseAddress(surf),
        IOSurfaceGetBytesPerRow(surf),
        (int)IOSurfaceGetWidth(surf),
        (int)IOSurfaceGetHeight(surf), x, y);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&g_surfaceLock);
    return rgb;
}

void tapcore_exec_tap(double x, double y) {
    sendTouchEvent(1, x, y, 0);
    usleep(25000);
    sendTouchEvent(1, x, y, 2);
    usleep(50000);
}

void tapcore_exec_swipe(double x1, double y1, double x2, double y2, int steps) {
    if (steps < 2) steps = 15;
    sendTouchEvent(1, x1, y1, 0);
    usleep(20000);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        sendTouchEvent(1, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 1);
        usleep(12000);
    }
    sendTouchEvent(1, x2, y2, 2);
    usleep(50000);
}

void tapcore_exec_home(void) {
    sendHIDKey(0x0C, 0x40, true);
    usleep(50000);
    sendHIDKey(0x0C, 0x40, false);
    usleep(50000);
}

void tapcore_exec_text(const char *utf8) {
    if (!utf8) return;
    size_t len = strlen(utf8);
    if (isPureASCII(utf8, len)) {
        typeASCII(utf8, len);
        usleep(30000);
        return;
    }
    if (!dispatchTweakCommand("input", utf8, len, 320)) {
        typeASCII(utf8, len);
    }
}

// ---------------- Touch Recorder (IOKit HID Callback) ----------------
static pthread_mutex_t g_recLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL            g_recActive = NO;
static CFRunLoopRef    g_recRunLoop = NULL;
static pthread_t       g_recThread;
static BOOL            g_recHasThread = NO;
static NSMutableString *g_recLua = nil;
static int             g_recEventCount = 0;
static double          g_recLastTsUs = 0;
static BOOL            g_recFingerDown[16] = {0};
static double          g_recLastX[16] = {0};
static double          g_recLastY[16] = {0};

static double nowUs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec * 1e6 + (double)tv.tv_usec;
}

static void recordDigitizerChild(IOHIDEventRef child) {
    int fid = (int)p_IOHIDEventGetIntegerValue(child, (11 << 16) | 5);
    if (fid < 0 || fid >= 16) fid = 0;
    BOOL touch = p_IOHIDEventGetIntegerValue(child, (11 << 16) | 9) != 0;
    double nx = p_IOHIDEventGetFloatValue(child, (11 << 16) | 0);
    double ny = p_IOHIDEventGetFloatValue(child, (11 << 16) | 1);
    double px = nx * (double)g_screenW;
    double py = ny * (double)g_screenH;

    double now = nowUs();
    BOOL wasDown = g_recFingerDown[fid];

    if (!wasDown && touch) {
        if (g_recLastTsUs > 0 && now - g_recLastTsUs >= 1000.0) {
            [g_recLua appendFormat:@"usleep(%.0f);\n", now - g_recLastTsUs];
        }
        [g_recLua appendFormat:@"touchDown(%d, %.2f, %.2f);\n", fid, px, py];
        g_recFingerDown[fid] = YES;
        g_recLastX[fid] = px;
        g_recLastY[fid] = py;
        g_recLastTsUs = now;
        g_recEventCount++;
    } else if (wasDown && touch) {
        double dist = hypot(px - g_recLastX[fid], py - g_recLastY[fid]);
        if (dist >= 2.5) {
            if (g_recLastTsUs > 0 && now - g_recLastTsUs >= 1000.0) {
                [g_recLua appendFormat:@"usleep(%.0f);\n", now - g_recLastTsUs];
            }
            [g_recLua appendFormat:@"touchMove(%d, %.2f, %.2f);\n", fid, px, py];
            g_recLastX[fid] = px;
            g_recLastY[fid] = py;
            g_recLastTsUs = now;
            g_recEventCount++;
        }
    } else if (wasDown && !touch) {
        if (g_recLastTsUs > 0 && now - g_recLastTsUs >= 1000.0) {
            [g_recLua appendFormat:@"usleep(%.0f);\n", now - g_recLastTsUs];
        }
        [g_recLua appendFormat:@"touchUp(%d, %.2f, %.2f);\n", fid, px, py];
        g_recFingerDown[fid] = NO;
        g_recLastTsUs = now;
        g_recEventCount++;
    }
}

static void recorderHIDCallback(void *target, void *refcon, IOHIDServiceClientRef service, IOHIDEventRef event) {
    (void)target; (void)refcon; (void)service;
    if (!event || !p_IOHIDEventGetType) return;
    if (p_IOHIDEventGetType(event) != 11) return; // Digitizer only

    pthread_mutex_lock(&g_recLock);
    if (!g_recActive) { pthread_mutex_unlock(&g_recLock); return; }
    CFArrayRef children = p_IOHIDEventGetChildren ? p_IOHIDEventGetChildren(event) : NULL;
    if (children) {
        CFIndex n = CFArrayGetCount(children);
        for (CFIndex i = 0; i < n; i++) {
            IOHIDEventRef ch = (IOHIDEventRef)CFArrayGetValueAtIndex(children, i);
            if (ch) recordDigitizerChild(ch);
        }
    }
    pthread_mutex_unlock(&g_recLock);
}

static void *recorderThreadMain(void *arg) {
    (void)arg;
    @autoreleasepool {
        IOHIDEventSystemClientRef recClient = p_IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!recClient) return NULL;
        CFRunLoopRef rl = CFRunLoopGetCurrent();
        pthread_mutex_lock(&g_recLock);
        g_recRunLoop = rl;
        pthread_mutex_unlock(&g_recLock);

        p_IOHIDEventSystemClientScheduleWithRunLoop(recClient, rl, kCFRunLoopDefaultMode);
        p_IOHIDEventSystemClientRegisterEventCallback(recClient, recorderHIDCallback, NULL, NULL);

        CFRunLoopRun();

        p_IOHIDEventSystemClientUnregisterEventCallback(recClient);
        p_IOHIDEventSystemClientUnscheduleWithRunLoop(recClient, rl, kCFRunLoopDefaultMode);
        CFRelease(recClient);

        pthread_mutex_lock(&g_recLock);
        g_recRunLoop = NULL;
        pthread_mutex_unlock(&g_recLock);
    }
    return NULL;
}

int tapcore_recorder_start(void) {
    if (!p_IOHIDEventSystemClientRegisterEventCallback || !p_IOHIDEventSystemClientScheduleWithRunLoop) {
        tapcore_log("ERR", "Touch recorder IOKit callback symbols unavailable");
        return -1;
    }
    tapcore_recorder_stop();

    pthread_mutex_lock(&g_recLock);
    g_recActive = YES;
    g_recLua = [NSMutableString stringWithString:@"-- Recorded by TapCore\n"];
    g_recEventCount = 0;
    g_recLastTsUs = 0;
    memset(g_recFingerDown, 0, sizeof(g_recFingerDown));
    int rc = pthread_create(&g_recThread, NULL, recorderThreadMain, NULL);
    g_recHasThread = (rc == 0);
    pthread_mutex_unlock(&g_recLock);

    if (rc == 0) tapcore_log("REC", "Touch recording started");
    return rc;
}

NSString *tapcore_recorder_stop(void) {
    CFRunLoopRef rl = NULL;
    pthread_t th;
    BOOL hasTh = NO;

    pthread_mutex_lock(&g_recLock);
    g_recActive = NO;
    rl = g_recRunLoop;
    th = g_recThread;
    hasTh = g_recHasThread;
    g_recHasThread = NO;
    pthread_mutex_unlock(&g_recLock);

    if (rl) CFRunLoopStop(rl);
    if (hasTh) pthread_join(th, NULL);

    pthread_mutex_lock(&g_recLock);
    NSString *result = g_recLua ? [g_recLua copy] : @"";
    int cnt = g_recEventCount;
    pthread_mutex_unlock(&g_recLock);

    if (hasTh) tapcore_log("REC", "Touch recording stopped (%d events)", cnt);
    return result;
}

BOOL tapcore_recorder_is_active(void) {
    pthread_mutex_lock(&g_recLock);
    BOOL a = g_recActive;
    pthread_mutex_unlock(&g_recLock);
    return a;
}

int tapcore_recorder_event_count(void) {
    pthread_mutex_lock(&g_recLock);
    int c = g_recEventCount;
    pthread_mutex_unlock(&g_recLock);
    return c;
}

NSString *tapcore_recorder_current_lua(void) {
    pthread_mutex_lock(&g_recLock);
    NSString *s = g_recLua ? [g_recLua copy] : @"";
    pthread_mutex_unlock(&g_recLock);
    return s;
}
