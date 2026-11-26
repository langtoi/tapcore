#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <unistd.h>

#include "tapcore.h"

static int g_activeWebPort = 0;

int tapcore_web_active_port(void) {
    return g_activeWebPort;
}

static NSString *localWiFiIP(void) {
    NSString *ip = @"127.0.0.1";
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == 0) {
        for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
            if ([name isEqualToString:@"en0"] || [name isEqualToString:@"en1"]) {
                char buf[INET_ADDRSTRLEN] = {0};
                struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
                if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                    ip = [NSString stringWithUTF8String:buf];
                    break;
                }
            }
        }
        freeifaddrs(ifaddr);
    }
    return ip;
}

static NSString *urlDecode(NSString *s) {
    if (!s) return @"";
    NSString *plusFixed = [s stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [plusFixed stringByRemovingPercentEncoding] ?: plusFixed;
}

static NSDictionary<NSString *, NSString *> *parseQuery(NSString *qs) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (qs.length == 0) return d;
    for (NSString *pair in [qs componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            NSString *k = urlDecode(pair);
            if (k.length) d[k] = @"";
        } else {
            NSString *k = urlDecode([pair substringToIndex:eq.location]);
            NSString *v = urlDecode([pair substringFromIndex:eq.location + 1]);
            if (k.length) d[k] = v;
        }
    }
    return d;
}

static NSString *safeRelPath(NSString *p) {
    if (!p) return nil;
    while ([p hasPrefix:@"/"]) p = [p substringFromIndex:1];
    if (p.length == 0 || [p containsString:@".."]) return nil;
    return p;
}

static void sendAllBytes(int fd, const void *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t w = send(fd, (const char *)buf + sent, len - sent, 0);
        if (w <= 0) {
            if (w < 0 && errno == EINTR) continue;
            break;
        }
        sent += (size_t)w;
    }
}

static void sendResponse(int fd, int code, const char *reason, const char *ctype, const void *body, size_t len) {
    char hdr[512];
    int hn = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n",
        code, reason, ctype, len);
    if (hn > 0) sendAllBytes(fd, hdr, (size_t)hn);
    if (body && len > 0) sendAllBytes(fd, body, len);
}

static void sendJSON(int fd, int code, id obj) {
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
    if (!d) d = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    const char *reason = (code == 200) ? "OK" : (code == 400) ? "Bad Request" : (code == 404) ? "Not Found" : "Error";
    sendResponse(fd, code, reason, "application/json; charset=utf-8", d.bytes, d.length);
}

static void handleWebClient(int cfd) {
    @autoreleasepool {
        struct timeval tv = {15, 0};
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        int opt = 1;
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

        // Read HTTP headers up to \r\n\r\n
        NSMutableData *raw = [NSMutableData data];
        char tmp[4096];
        NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
        NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];

        while (raw.length < 65536) {
            ssize_t r = recv(cfd, tmp, sizeof(tmp), 0);
            if (r <= 0) break;
            [raw appendBytes:tmp length:(size_t)r];
            hdrEnd = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
            if (hdrEnd.location != NSNotFound) break;
        }
        if (hdrEnd.location == NSNotFound) return;

        NSString *hdrStr = [[NSString alloc] initWithBytes:raw.bytes length:hdrEnd.location encoding:NSUTF8StringEncoding];
        NSArray<NSString *> *lines = [hdrStr componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) return;

        NSArray<NSString *> *reqParts = [lines[0] componentsSeparatedByString:@" "];
        if (reqParts.count < 2) return;
        NSString *method = reqParts[0].uppercaseString;
        NSString *target = reqParts[1];

        if ([method isEqualToString:@"OPTIONS"]) {
            sendResponse(cfd, 204, "No Content", "text/plain", "", 0);
            return;
        }

        size_t contentLen = 0;
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *k = [[lines[i] substringToIndex:colon.location] lowercaseString];
            NSString *v = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([k isEqualToString:@"content-length"]) {
                contentLen = (size_t)strtoull(v.UTF8String, NULL, 10);
            }
        }
        if (contentLen > 25 * 1024 * 1024) {
            sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Payload too large"});
            return;
        }

        NSUInteger bodyOffset = hdrEnd.location + 4;
        NSMutableData *body = [NSMutableData dataWithCapacity:contentLen];
        if (raw.length > bodyOffset) {
            [body appendBytes:(const char *)raw.bytes + bodyOffset length:raw.length - bodyOffset];
        }
        while (body.length < contentLen) {
            size_t want = contentLen - body.length;
            if (want > sizeof(tmp)) want = sizeof(tmp);
            ssize_t r = recv(cfd, tmp, want, 0);
            if (r <= 0) break;
            [body appendBytes:tmp length:(size_t)r];
        }

        NSString *path = target;
        NSString *qs = @"";
        NSRange qm = [target rangeOfString:@"?"];
        if (qm.location != NSNotFound) {
            path = [target substringToIndex:qm.location];
            qs = [target substringFromIndex:qm.location + 1];
        }
        NSDictionary<NSString *, NSString *> *query = parseQuery(qs);
        NSString *scriptsDir = tapcore_scripts_dir();
        NSString *shotsDir = [scriptsDir stringByAppendingPathComponent:@"Screenshots"];
        NSFileManager *fm = [NSFileManager defaultManager];

        // ---- 1. AutoTouch / BAS Control Compatibility ----
        if ([path isEqualToString:@"/control/start_playing"]) {
            NSString *rel = safeRelPath(query[@"path"] ?: @"sv.lua");
            NSDictionary *st = tapcore_runner_status();
            if ([st[@"running"] boolValue] && [st[@"script"] isEqualToString:rel]) {
                sendJSON(cfd, 200, @{@"status": @"success", @"already_running": @YES, @"script": rel});
                return;
            }
            NSString *err = nil;
            if (tapcore_runner_play(rel.UTF8String, &err) == 0) {
                sendJSON(cfd, 200, @{@"status": @"success", @"script": rel});
            } else {
                sendJSON(cfd, 404, @{@"status": @"error", @"error": err ?: @"failed"});
            }
            return;
        }
        if ([path isEqualToString:@"/control/stop_playing"]) {
            tapcore_runner_stop();
            sendJSON(cfd, 200, @{@"status": @"success"});
            return;
        }

        // ---- 2. Web Studio HTML UI ----
        if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
            NSString *htmlPath = [@TAPCORE_WEB_DIR stringByAppendingPathComponent:@"index.html"];
            NSData *html = [NSData dataWithContentsOfFile:htmlPath];
            if (html) {
                sendResponse(cfd, 200, "OK", "text/html; charset=utf-8", html.bytes, html.length);
            } else {
                const char *msg = "<h1>TapCore Web UI missing</h1><p>Expected /var/jb/usr/share/tapcore/web/index.html</p>";
                sendResponse(cfd, 404, "Not Found", "text/html; charset=utf-8", msg, strlen(msg));
            }
            return;
        }

        // ---- 3. Status & Config ----
        if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/status"]) {
            NSMutableDictionary *st = [tapcore_runner_status() mutableCopy];
            st[@"ip"] = localWiFiIP();
            sendJSON(cfd, 200, st);
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/config"]) {
            id obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if (![obj isKindOfClass:[NSDictionary class]]) {
                sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Invalid JSON"});
                return;
            }
            BOOL ok = tapcore_runner_update_config((NSDictionary *)obj);
            sendJSON(cfd, ok ? 200 : 500, @{@"success": @(ok), @"config": tapcore_runner_get_config()});
            return;
        }

        // ---- 4. Logs ----
        if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/logs"]) {
            uint64_t since = query[@"since"] ? strtoull(query[@"since"].UTF8String, NULL, 10) : 0;
            sendJSON(cfd, 200, @{@"logs": tapcore_logs_since(since)});
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/logs/clear"]) {
            tapcore_logs_clear();
            sendJSON(cfd, 200, @{@"success": @YES});
            return;
        }

        // ---- 5. Scripts CRUD + Play/Stop ----
        if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/scripts"]) {
            NSDictionary *st = tapcore_runner_status();
            NSString *activeScript = [st[@"running"] boolValue] ? st[@"script"] : @"";
            NSMutableArray *list = [NSMutableArray array];
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:scriptsDir error:nil] ?: @[];
            for (NSString *name in items) {
                if (![name.lowercaseString hasSuffix:@".lua"]) continue;
                NSString *full = [scriptsDir stringByAppendingPathComponent:name];
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                [list addObject:@{
                    @"name": name,
                    @"path": name,
                    @"size": attrs[NSFileSize] ?: @(0),
                    @"mtime": @([(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970]),
                    @"running": @([activeScript isEqualToString:name])
                }];
            }
            [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
            }];
            sendJSON(cfd, 200, @{@"scripts": list, @"dir": scriptsDir});
            return;
        }
        if ([path isEqualToString:@"/api/script"]) {
            NSString *rel = safeRelPath(query[@"path"]);
            if (!rel) { sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Invalid path"}); return; }
            NSString *full = [scriptsDir stringByAppendingPathComponent:rel];
            if ([method isEqualToString:@"GET"]) {
                NSData *d = [NSData dataWithContentsOfFile:full];
                if (!d) { sendJSON(cfd, 404, @{@"success": @NO, @"error": @"Not found"}); return; }
                sendResponse(cfd, 200, "OK", "text/plain; charset=utf-8", d.bytes, d.length);
            } else if ([method isEqualToString:@"POST"]) {
                [fm createDirectoryAtPath:[full stringByDeletingLastPathComponent]
              withIntermediateDirectories:YES attributes:nil error:nil];
                BOOL ok = [body writeToFile:full atomically:YES];
                if (ok) tapcore_log("FILE", "Saved script %s (%lu bytes)", rel.UTF8String, (unsigned long)body.length);
                sendJSON(cfd, ok ? 200 : 500, @{@"success": @(ok), @"path": rel});
            } else if ([method isEqualToString:@"DELETE"]) {
                BOOL ok = [fm removeItemAtPath:full error:nil];
                if (ok) tapcore_log("FILE", "Deleted script %s", rel.UTF8String);
                sendJSON(cfd, ok ? 200 : 404, @{@"success": @(ok)});
            }
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/run"]) {
            NSString *rel = safeRelPath(query[@"path"]);
            if (!rel) { sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Missing path"}); return; }
            NSString *err = nil;
            int rc = tapcore_runner_play(rel.UTF8String, &err);
            sendJSON(cfd, rc == 0 ? 200 : 400, @{@"success": @(rc == 0), @"script": rel, @"error": err ?: @""});
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/stop"]) {
            tapcore_runner_stop();
            sendJSON(cfd, 200, @{@"success": @YES});
            return;
        }

        // ---- 6. Screenshots, Capture, Crop ----
        if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/screenshots"]) {
            [fm createDirectoryAtPath:shotsDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableArray *list = [NSMutableArray array];
            NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:shotsDir error:nil] ?: @[];
            for (NSString *name in items) {
                NSString *low = name.lowercaseString;
                if (!([low hasSuffix:@".png"] || [low hasSuffix:@".jpg"] || [low hasSuffix:@".jpeg"])) continue;
                NSString *full = [shotsDir stringByAppendingPathComponent:name];
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                [list addObject:@{
                    @"name": name,
                    @"size": attrs[NSFileSize] ?: @(0),
                    @"mtime": @([(NSDate *)attrs[NSFileModificationDate] timeIntervalSince1970])
                }];
            }
            [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"mtime"] compare:a[@"mtime"]];
            }];
            sendJSON(cfd, 200, @{@"screenshots": list});
            return;
        }
        if ([path isEqualToString:@"/api/screenshot/file"]) {
            NSString *name = safeRelPath(query[@"name"]);
            if (!name) { sendJSON(cfd, 400, @{@"error": @"Invalid name"}); return; }
            NSString *full = [shotsDir stringByAppendingPathComponent:name];
            if ([method isEqualToString:@"GET"]) {
                NSData *d = [NSData dataWithContentsOfFile:full];
                if (!d) { sendJSON(cfd, 404, @{@"error": @"Not found"}); return; }
                const char *ct = [name.lowercaseString hasSuffix:@".png"] ? "image/png" : "image/jpeg";
                sendResponse(cfd, 200, "OK", ct, d.bytes, d.length);
            } else if ([method isEqualToString:@"DELETE"]) {
                BOOL ok = [fm removeItemAtPath:full error:nil];
                sendJSON(cfd, ok ? 200 : 404, @{@"success": @(ok)});
            }
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/screenshot/upload"]) {
            NSString *name = safeRelPath(query[@"name"]);
            if (!name) { sendJSON(cfd, 400, @{@"error": @"Invalid name"}); return; }
            [fm createDirectoryAtPath:shotsDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *full = [shotsDir stringByAppendingPathComponent:name];
            BOOL ok = [body writeToFile:full atomically:YES];
            sendJSON(cfd, ok ? 200 : 500, @{@"success": @(ok), @"name": name});
            return;
        }
        if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/capture"]) {
            double delay = query[@"delay"] ? query[@"delay"].doubleValue : 0;
            if (delay > 0 && delay <= 15) usleep((useconds_t)(delay * 1e6));
            int w = 0, h = 0;
            NSData *png = tapcore_capture_png(&w, &h);
            if (!png) { sendJSON(cfd, 500, @{@"error": @"Capture failed"}); return; }
            NSString *saveName = safeRelPath(query[@"save"]);
            if (saveName) {
                [fm createDirectoryAtPath:shotsDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *full = [shotsDir stringByAppendingPathComponent:saveName];
                [png writeToFile:full atomically:YES];
                tapcore_log("IMG", "Saved capture %s (%dx%d)", saveName.UTF8String, w, h);
                if ([query[@"json"] isEqualToString:@"1"]) {
                    sendJSON(cfd, 200, @{@"success": @YES, @"name": saveName, @"width": @(w), @"height": @(h)});
                    return;
                }
            }
            sendResponse(cfd, 200, "OK", "image/png", png.bytes, png.length);
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/crop"]) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if (![j isKindOfClass:[NSDictionary class]]) {
                sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Invalid JSON"});
                return;
            }
            NSString *srcName = j[@"source"];
            NSString *saveName = safeRelPath(j[@"save"]);
            int x = [j[@"x"] intValue], y = [j[@"y"] intValue];
            int w = [j[@"width"] intValue], h = [j[@"height"] intValue];
            if (!saveName || w <= 0 || h <= 0) {
                sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Require save name and positive width/height"});
                return;
            }
            NSData *srcPng = nil;
            if (!srcName || [srcName isEqualToString:@"live"] || srcName.length == 0) {
                srcPng = tapcore_capture_png(NULL, NULL);
            } else {
                NSString *cleanSrc = safeRelPath(srcName);
                if (cleanSrc) {
                    srcPng = [NSData dataWithContentsOfFile:[shotsDir stringByAppendingPathComponent:cleanSrc]];
                }
            }
            NSData *cropped = tapcore_crop_png_data(srcPng, x, y, w, h);
            if (!cropped) {
                sendJSON(cfd, 500, @{@"success": @NO, @"error": @"Crop failed"});
                return;
            }
            [fm createDirectoryAtPath:shotsDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *dstPath = [shotsDir stringByAppendingPathComponent:saveName];
            BOOL ok = [cropped writeToFile:dstPath atomically:YES];
            if (ok) tapcore_log("IMG", "Cropped %s (%dx%d at %d,%d)", saveName.UTF8String, w, h, x, y);
            sendJSON(cfd, ok ? 200 : 500, @{
                @"success": @(ok),
                @"name": saveName,
                @"image_path": [NSString stringWithFormat:@"Screenshots/%@", saveName],
                @"width": @(w),
                @"height": @(h)
            });
            return;
        }

        // ---- 7. Vision OCR & Direct Live Test ----
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/ocr"]) {
            NSDictionary *j = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : @{};
            BOOL hasReg = NO;
            int rx = 0, ry = 0, rw = 0, rh = 0;
            id reg = [j isKindOfClass:[NSDictionary class]] ? j[@"region"] : nil;
            if ([reg isKindOfClass:[NSArray class]] && [(NSArray *)reg count] >= 4) {
                NSArray *a = (NSArray *)reg;
                rx = [a[0] intValue]; ry = [a[1] intValue]; rw = [a[2] intValue]; rh = [a[3] intValue];
                hasReg = YES;
            } else if ([reg isKindOfClass:[NSDictionary class]]) {
                rx = [reg[@"x"] intValue]; ry = [reg[@"y"] intValue];
                rw = [reg[@"width"] intValue]; rh = [reg[@"height"] intValue];
                hasReg = (rw > 0 && rh > 0);
            }
            NSArray *langs = ([j isKindOfClass:[NSDictionary class]] && [j[@"languages"] isKindOfClass:[NSArray class]])
                ? j[@"languages"] : @[@"en-US"];
            NSDictionary *res = tapcore_ocr_dict(hasReg, rx, ry, rw, rh, langs);
            sendJSON(cfd, res[@"error"] ? 500 : 200, res);
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/test"]) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            NSString *op = [j isKindOfClass:[NSDictionary class]] ? j[@"op"] : nil;
            if ([op isEqualToString:@"tap"]) {
                tapcore_exec_tap([j[@"x"] doubleValue], [j[@"y"] doubleValue]);
                sendJSON(cfd, 200, @{@"success": @YES});
            } else if ([op isEqualToString:@"swipe"]) {
                tapcore_exec_swipe([j[@"x1"] doubleValue], [j[@"y1"] doubleValue],
                                 [j[@"x2"] doubleValue], [j[@"y2"] doubleValue],
                                 [j[@"steps"] intValue] ?: 16);
                sendJSON(cfd, 200, @{@"success": @YES});
            } else if ([op isEqualToString:@"home"]) {
                tapcore_exec_home();
                sendJSON(cfd, 200, @{@"success": @YES});
            } else if ([op isEqualToString:@"text"]) {
                NSString *t = j[@"data"];
                tapcore_exec_text(t ? t.UTF8String : "");
                sendJSON(cfd, 200, @{@"success": @YES});
            } else if ([op isEqualToString:@"color"]) {
                int x = [j[@"x"] intValue], y = [j[@"y"] intValue];
                uint32_t rgb = tapcore_read_pixel(x, y);
                sendJSON(cfd, 200, @{
                    @"success": @YES,
                    @"color": @(rgb),
                    @"hex": [NSString stringWithFormat:@"0x%06X", rgb]
                });
            } else {
                sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Unknown op"});
            }
            return;
        }

        // ---- 8. System Tools (uicache, respring, restart_daemon) ----
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/system"]) {
            NSDictionary *j = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : @{};
            NSString *op = [j isKindOfClass:[NSDictionary class]] ? j[@"op"] : nil;
            if ([op isEqualToString:@"uicache"]) {
                tapcore_log("SYS", "Running uicache -a ...");
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    pid_t pid = fork();
                    if (pid == 0) {
                        setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
                        const char *bin = (access("/var/jb/usr/bin/uicache", X_OK) == 0)
                            ? "/var/jb/usr/bin/uicache" : "/usr/bin/uicache";
                        execl(bin, "uicache", "-a", (char *)NULL);
                        _exit(127);
                    } else if (pid > 0) {
                        int st = 0;
                        waitpid(pid, &st, 0);
                        tapcore_log("SYS", "uicache -a finished (exit=%d)", WIFEXITED(st) ? WEXITSTATUS(st) : -1);
                    }
                });
                sendJSON(cfd, 200, @{@"success": @YES, @"op": @"uicache", @"message": @"uicache -a started"});
                return;
            }
            if ([op isEqualToString:@"respring"]) {
                tapcore_log("SYS", "Respring requested...");
                sendJSON(cfd, 200, @{@"success": @YES, @"op": @"respring", @"message": @"Respringing SpringBoard"});
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    usleep(250000);
                    pid_t pid = fork();
                    if (pid == 0) {
                        setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
                        if (access("/var/jb/usr/bin/sbreload", X_OK) == 0) {
                            execl("/var/jb/usr/bin/sbreload", "sbreload", (char *)NULL);
                        }
                        const char *ka = (access("/var/jb/usr/bin/killall", X_OK) == 0)
                            ? "/var/jb/usr/bin/killall" : "/usr/bin/killall";
                        execl(ka, "killall", "-9", "SpringBoard", (char *)NULL);
                        _exit(127);
                    }
                });
                return;
            }
            if ([op isEqualToString:@"restart_daemon"]) {
                tapcore_log("SYS", "Restarting tapcore daemon...");
                sendJSON(cfd, 200, @{@"success": @YES, @"op": @"restart_daemon", @"message": @"Restarting daemon"});
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    usleep(300000);
                    _exit(0); // launchd KeepAlive automatically respawns tapcore cleanly
                });
                return;
            }
            sendJSON(cfd, 400, @{@"success": @NO, @"error": @"Unknown system op (use uicache, respring, restart_daemon)"});
            return;
        }

        // ---- 9. Touch Recorder ----
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/record/start"]) {
            int rc = tapcore_recorder_start();
            sendJSON(cfd, rc == 0 ? 200 : 500, @{@"success": @(rc == 0), @"recording": @(rc == 0)});
            return;
        }
        if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/record/stop"]) {
            NSString *lua = tapcore_recorder_stop();
            NSString *saveAs = safeRelPath(query[@"save"]);
            if (saveAs) {
                NSString *full = [scriptsDir stringByAppendingPathComponent:saveAs];
                [lua writeToFile:full atomically:YES encoding:NSUTF8StringEncoding error:nil];
                tapcore_log("REC", "Saved recording to %s", saveAs.UTF8String);
            }
            sendJSON(cfd, 200, @{
                @"success": @YES,
                @"recording": @NO,
                @"events": @(tapcore_recorder_event_count()),
                @"lua": lua ?: @"",
                @"saved": saveAs ?: @""
            });
            return;
        }
        if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/record/status"]) {
            sendJSON(cfd, 200, @{
                @"recording": @(tapcore_recorder_is_active()),
                @"events": @(tapcore_recorder_event_count()),
                @"lua": tapcore_recorder_current_lua() ?: @""
            });
            return;
        }

        sendJSON(cfd, 404, @{@"error": @"Not found", @"path": path});
    }
}

static void *clientThreadEntry(void *arg) {
    int cfd = (int)(intptr_t)arg;
    handleWebClient(cfd);
    close(cfd);
    return NULL;
}

static void *webServerAcceptLoop(void *arg) {
    int srv = (int)(intptr_t)arg;
    for (;;) {
        int cfd = accept(srv, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            usleep(20000);
            continue;
        }
        pthread_t th;
        if (pthread_create(&th, NULL, clientThreadEntry, (void *)(intptr_t)cfd) == 0) {
            pthread_detach(th);
        } else {
            close(cfd);
        }
    }
    return NULL;
}

static int bindPort(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 64) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int tapcore_web_start(int preferredPort, int fallbackPort) {
    int srv = bindPort(preferredPort);
    int chosen = preferredPort;
    if (srv < 0 && fallbackPort > 0 && fallbackPort != preferredPort) {
        tapcore_log("WEB", "Port %d busy, trying fallback port %d", preferredPort, fallbackPort);
        srv = bindPort(fallbackPort);
        chosen = fallbackPort;
    }
    if (srv < 0) {
        tapcore_log("ERR", "Could not bind web port %d or %d", preferredPort, fallbackPort);
        return -1;
    }
    g_activeWebPort = chosen;

    // Record active port for TapCore.app local discovery
    FILE *fp = fopen(TAPCORE_PORT_FILE, "w");
    if (fp) {
        fprintf(fp, "%d\n", chosen);
        fclose(fp);
    }

    tapcore_log("WEB", "TapCore Web Server listening on http://%s:%d",
              localWiFiIP().UTF8String, chosen);

    pthread_t th;
    pthread_create(&th, NULL, webServerAcceptLoop, (void *)(intptr_t)srv);
    pthread_detach(th);
    return 0;
}
