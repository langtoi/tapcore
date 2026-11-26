#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
#include "lua.h"

#define TAPCORE_CONFIG_DIR   "/var/jb/var/mobile/Library/TapCore"
#define TAPCORE_WEB_DIR      "/var/jb/usr/share/tapcore/web"
#define TAPCORE_CONFIG_FILE  "/var/jb/var/mobile/Library/TapCore/config.json"
#define TAPCORE_SCRIPTS_DIR  "/var/jb/var/mobile/Library/TapCore/Scripts"
#define TAPCORE_PORT_FILE    "/tmp/tapcore.port"

#ifndef TAPCORE_VERSION
#define TAPCORE_VERSION "dev"   // build.sh passes the VERSION file
#endif

// Core init & IPC
int  tapcore_core_init(void);
long long tapcore_daemon_started(void);   // unix time the daemon started
void tapcore_core_start_ipc(void);
void tapcore_core_register_lua(lua_State *L);

// Screen / device info
int      tapcore_screen_width(void);
int      tapcore_screen_height(void);
uint64_t tapcore_sender_id(void);
NSString *tapcore_scripts_dir(void);
void     tapcore_set_scripts_dir(NSString *dir);

// Interruptible script stop flag
void tapcore_script_reset_stop(void);
void tapcore_script_request_stop(void);
int  tapcore_script_should_stop(void);

// Ring-buffer live logging
void     tapcore_log(const char *tag, const char *fmt, ...);
NSArray *tapcore_logs_since(uint64_t sinceId);
void     tapcore_logs_clear(void);

// Direct native operations for Web/App Studio REST API
NSData       *tapcore_capture_png(int *outW, int *outH);
NSData       *tapcore_crop_png_data(NSData *pngData, int x, int y, int w, int h);
NSDictionary *tapcore_ocr_dict(NSDictionary *opts);
uint32_t      tapcore_read_pixel(int x, int y);
void          tapcore_exec_tap(double x, double y);
void          tapcore_exec_swipe(double x1, double y1, double x2, double y2, int steps);
void          tapcore_exec_home(void);
BOOL          tapcore_exec_text(const char *s, size_t len, char *how, size_t howLen);
BOOL          tapcore_copy_text(const char *s, size_t len, char *how, size_t howLen);

// Touch Recorder (IOKit HID event callback)
int       tapcore_recorder_start(void);
NSString *tapcore_recorder_stop(void);
BOOL      tapcore_recorder_is_active(void);
int       tapcore_recorder_event_count(void);
NSString *tapcore_recorder_current_lua(void);

// Script Runner & Web Server
void          tapcore_runner_load_config(void);
NSDictionary *tapcore_runner_get_config(void);
BOOL          tapcore_runner_update_config(NSDictionary *patch);
int           tapcore_runner_play(const char *relPath, NSString **outErr);
int           tapcore_runner_stop(void);
NSDictionary *tapcore_runner_status(void);
void          tapcore_runner_autostart_if_configured(void);

int  tapcore_web_start(int preferredPort, int fallbackPort);
int  tapcore_web_active_port(void);

// Lua preloaded modules
int luaopen_tapcore_socket(lua_State *L);
int luaopen_tapcore_json(lua_State *L);
