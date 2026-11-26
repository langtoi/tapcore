#import <Foundation/Foundation.h>
#import <pthread.h>
#import <pthread/qos.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "tapcore.h"

static pthread_mutex_t g_runnerLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL            g_isRunning = NO;
static pthread_t       g_workerThread;
static BOOL            g_hasWorker = NO;
static NSString       *g_currentScript = nil;
static double          g_startedAt = 0;
static NSString       *g_lastError = nil;

static NSMutableDictionary *g_config = nil;

static void ensureDir(const char *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:path]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

void tapcore_runner_load_config(void) {
    @autoreleasepool {
        ensureDir(TAPCORE_CONFIG_DIR);
        ensureDir(TAPCORE_WEB_DIR);

        NSMutableDictionary *def = [@{
            @"web_port": @(8080),
            @"fallback_port": @(8088),
            @"web_enabled": @YES,
            @"auto_start_script": @"",
            @"scripts_dir": @TAPCORE_SCRIPTS_DIR
        } mutableCopy];

        NSData *data = [NSData dataWithContentsOfFile:@TAPCORE_CONFIG_FILE];
        if (data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                [def addEntriesFromDictionary:(NSDictionary *)obj];
            }
        }
        NSString *cfgDir = def[@"scripts_dir"];
        if ([cfgDir isKindOfClass:[NSString class]] &&
            [[cfgDir stringByResolvingSymlinksInPath] isEqualToString:[@TAPCORE_SCRIPTS_DIR stringByResolvingSymlinksInPath]]) {
            def[@"scripts_dir"] = @TAPCORE_SCRIPTS_DIR;
        }
        pthread_mutex_lock(&g_runnerLock);
        g_config = def;
        NSString *sdir = def[@"scripts_dir"];
        pthread_mutex_unlock(&g_runnerLock);

        if ([sdir isKindOfClass:[NSString class]] && sdir.length > 0) {
            tapcore_set_scripts_dir(sdir);
            ensureDir(sdir.UTF8String);
            NSString *shotDir = [sdir stringByAppendingPathComponent:@"Screenshots"];
            ensureDir(shotDir.UTF8String);
        }
    }
}

NSDictionary *tapcore_runner_get_config(void) {
    pthread_mutex_lock(&g_runnerLock);
    NSDictionary *copy = g_config ? [g_config copy] : @{};
    pthread_mutex_unlock(&g_runnerLock);
    return copy;
}

BOOL tapcore_runner_update_config(NSDictionary *patch) {
    if (![patch isKindOfClass:[NSDictionary class]]) return NO;
    @autoreleasepool {
        pthread_mutex_lock(&g_runnerLock);
        if (!g_config) g_config = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"web_port", @"fallback_port", @"web_enabled", @"auto_start_script", @"scripts_dir"]) {
            if (patch[k] != nil && patch[k] != [NSNull null]) {
                g_config[k] = patch[k];
            }
        }
        NSString *sdir = g_config[@"scripts_dir"];
        NSData *json = [NSJSONSerialization dataWithJSONObject:g_config
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        pthread_mutex_unlock(&g_runnerLock);

        if ([sdir isKindOfClass:[NSString class]] && sdir.length > 0) {
            tapcore_set_scripts_dir(sdir);
        }
        if (json) {
            ensureDir(TAPCORE_CONFIG_DIR);
            return [json writeToFile:@TAPCORE_CONFIG_FILE atomically:YES];
        }
    }
    return NO;
}

static void luaStopHook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (tapcore_script_should_stop()) {
        luaL_error(L, "__TAPCORE_STOPPED__");
    }
}

static int l_tapcore_print(lua_State *L) {
    int n = lua_gettop(L);
    NSMutableString *line = [NSMutableString string];
    lua_getglobal(L, "tostring");
    for (int i = 1; i <= n; i++) {
        lua_pushvalue(L, -1);
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        const char *s = lua_tostring(L, -1);
        if (i > 1) [line appendString:@"\t"];
        if (s) [line appendString:[NSString stringWithUTF8String:s]];
        lua_pop(L, 1);
    }
    tapcore_log("LUA", "%s", line.UTF8String);
    return 0;
}

static void *scriptWorkerMain(void *arg) {
    NSString *fullPath = (__bridge_transfer NSString *)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    @autoreleasepool {
        lua_State *L = luaL_newstate();
        if (!L) {
            tapcore_log("ERR", "luaL_newstate failed");
            pthread_mutex_lock(&g_runnerLock);
            g_isRunning = NO;
            g_lastError = @"luaL_newstate failed";
            pthread_mutex_unlock(&g_runnerLock);
            return NULL;
        }

        luaL_openlibs(L);

        // Preload socket and json
        lua_getglobal(L, "package");
        lua_getfield(L, -1, "preload");
        lua_pushcfunction(L, luaopen_tapcore_socket);
        lua_setfield(L, -2, "socket");
        lua_pushcfunction(L, luaopen_tapcore_json);
        lua_setfield(L, -2, "json");
        lua_pop(L, 2);

        // Override print -> live log buffer
        lua_pushcfunction(L, l_tapcore_print);
        lua_setglobal(L, "print");

        tapcore_core_register_lua(L);
        lua_sethook(L, luaStopHook, LUA_MASKCOUNT, 250);

        tapcore_log("RUN", "Started %s", fullPath.lastPathComponent.UTF8String);
        int status = luaL_dofile(L, fullPath.UTF8String);
        NSString *errText = nil;
        if (status != LUA_OK) {
            const char *e = lua_tostring(L, -1);
            if (e && strstr(e, "__TAPCORE_STOPPED__")) {
                tapcore_log("RUN", "Stopped %s", fullPath.lastPathComponent.UTF8String);
            } else {
                errText = e ? [NSString stringWithUTF8String:e] : @"Unknown Lua error";
                tapcore_log("ERR", "Lua error in %s: %s",
                          fullPath.lastPathComponent.UTF8String, errText.UTF8String);
            }
        } else {
            tapcore_log("RUN", "Finished %s", fullPath.lastPathComponent.UTF8String);
        }
        lua_close(L);

        pthread_mutex_lock(&g_runnerLock);
        g_isRunning = NO;
        g_currentScript = nil;
        g_startedAt = 0;
        g_lastError = errText;
        pthread_mutex_unlock(&g_runnerLock);
    }
    return NULL;
}

static NSString *sanitizeRelPath(const char *rel) {
    if (!rel) return nil;
    NSString *s = [NSString stringWithUTF8String:rel];
    while ([s hasPrefix:@"/"]) s = [s substringFromIndex:1];
    if (s.length == 0 || [s containsString:@".."]) return nil;
    return s;
}

int tapcore_runner_stop(void) {
    pthread_t thToJoin;
    BOOL needJoin = NO;

    pthread_mutex_lock(&g_runnerLock);
    if (g_isRunning) {
        tapcore_script_request_stop();
    }
    if (g_hasWorker) {
        thToJoin = g_workerThread;
        g_hasWorker = NO;
        needJoin = YES;
    }
    pthread_mutex_unlock(&g_runnerLock);

    if (needJoin) {
        pthread_join(thToJoin, NULL);
    }
    return 0;
}

int tapcore_runner_play(const char *relPath, NSString **outErr) {
    NSString *clean = sanitizeRelPath(relPath);
    if (!clean) {
        if (outErr) *outErr = @"Invalid script path";
        return -1;
    }
    NSString *base = tapcore_scripts_dir();
    NSString *full = [base stringByAppendingPathComponent:clean];
    if (![[NSFileManager defaultManager] fileExistsAtPath:full]) {
        if (outErr) *outErr = [NSString stringWithFormat:@"Script not found: %@", clean];
        return -2;
    }

    // Stop any currently running script cleanly first
    tapcore_runner_stop();

    pthread_mutex_lock(&g_runnerLock);
    tapcore_script_reset_stop();
    g_isRunning = YES;
    g_currentScript = clean;
    g_startedAt = [[NSDate date] timeIntervalSince1970];
    g_lastError = nil;

    int rc = pthread_create(&g_workerThread, NULL, scriptWorkerMain, (__bridge_retained void *)full);
    if (rc == 0) {
        g_hasWorker = YES;
    } else {
        g_isRunning = NO;
        g_currentScript = nil;
        if (outErr) *outErr = @"Failed to spawn worker thread";
    }
    pthread_mutex_unlock(&g_runnerLock);
    return rc;
}

void tapcore_runner_autostart_if_configured(void) {
    NSDictionary *cfg = tapcore_runner_get_config();
    NSString *autoScript = cfg[@"auto_start_script"];
    if ([autoScript isKindOfClass:[NSString class]] && autoScript.length > 0) {
        NSString *err = nil;
        if (tapcore_runner_play(autoScript.UTF8String, &err) != 0) {
            tapcore_log("WARN", "Auto-start '%s' failed: %s",
                      autoScript.UTF8String, err ? err.UTF8String : "error");
        }
    } else {
        tapcore_log("SYS", "Idle mode: no auto-start script configured");
    }
}

// Physical memory footprint of the daemon in MB (what Jetsam counts).
static double memoryFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return round(info.phys_footprint / 1048576.0 * 10.0) / 10.0;
}

NSDictionary *tapcore_runner_status(void) {
    pthread_mutex_lock(&g_runnerLock);
    BOOL running = g_isRunning;
    NSString *script = g_currentScript ? [g_currentScript copy] : @"";
    double started = g_startedAt;
    NSString *lastErr = g_lastError ? [g_lastError copy] : @"";
    NSString *autoStart = g_config[@"auto_start_script"] ?: @"";
    pthread_mutex_unlock(&g_runnerLock);

    double now = [[NSDate date] timeIntervalSince1970];
    double uptime = (running && started > 0) ? (now - started) : 0;

    return @{
        @"version": @TAPCORE_VERSION,
        @"daemon_started": @(tapcore_daemon_started()),
        @"memory_mb": @(memoryFootprintMB()),
        @"running": @(running),
        @"script": script,
        @"uptime_s": @((int)uptime),
        @"last_error": lastErr,
        @"web_port": @(tapcore_web_active_port()),
        @"screen_w": @(tapcore_screen_width()),
        @"screen_h": @(tapcore_screen_height()),
        @"sender_id": [NSString stringWithFormat:@"0x%llx", (unsigned long long)tapcore_sender_id()],
        @"recording": @(tapcore_recorder_is_active()),
        @"record_events": @(tapcore_recorder_event_count()),
        @"auto_start_script": autoStart,
        @"scripts_dir": tapcore_scripts_dir() ?: @""
    };
}
