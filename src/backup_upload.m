#import <Foundation/Foundation.h>
#include <sys/time.h>
#include "tapcore.h"

static NSString *const kDefaultUploadURL = @"https://panel.65.109.22.234.sslip.io/api/v1/upload/account";
static NSString *const kRestoreBaseURL   = @"http://127.0.0.1:9102";

static NSMutableDictionary<NSString *, NSMutableDictionary *> *g_jobs = nil;
static NSMutableArray<NSString *> *g_jobOrder = nil;
static NSString *g_latestJobId = nil;
static uint64_t g_jobSeq = 0;

static double nowMono(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static void ensureStore(void) {
    if (!g_jobs) {
        g_jobs = [NSMutableDictionary dictionary];
        g_jobOrder = [NSMutableArray array];
    }
}

static NSDictionary *snapshotJob(NSMutableDictionary *job) {
    if (!job) return nil;
    @synchronized(g_jobs) {
        NSMutableDictionary *copy = [job mutableCopy];
        NSArray *steps = job[@"steps"];
        if (steps) copy[@"steps"] = [steps copy];
        double started = [job[@"started_at"] doubleValue];
        if ([job[@"state"] isEqualToString:@"running"] && started > 0) {
            copy[@"elapsed_s"] = @(round((nowMono() - started) * 100.0) / 100.0);
        }
        return copy;
    }
}

static void jobUpdate(NSMutableDictionary *job, NSString *stage, NSString *msg, NSDictionary *extra) {
    @synchronized(g_jobs) {
        double started = [job[@"started_at"] doubleValue];
        double dt = started > 0 ? round((nowMono() - started) * 100.0) / 100.0 : 0.0;
        job[@"elapsed_s"] = @(dt);
        if (stage) job[@"stage"] = stage;
        if (msg) {
            job[@"message"] = msg;
            NSMutableArray *steps = job[@"steps"];
            if (steps) {
                [steps addObject:@{
                    @"t": @(dt),
                    @"stage": stage ?: (job[@"stage"] ?: @""),
                    @"msg": msg
                }];
            }
        }
        if (extra) {
            for (NSString *k in extra) {
                job[k] = extra[k];
            }
        }
    }
    if (msg) {
        tapcore_log("UPLOAD", "[%s] %s: %s",
                    [job[@"job_id"] UTF8String],
                    [(stage ?: @"") UTF8String],
                    msg.UTF8String);
    }
}

// Synchronous local JSON HTTP call (used for 127.0.0.1:9102)
static NSDictionary *localJSONRequest(NSString *method, NSString *urlStr, NSDictionary *jsonBody, double timeoutSec, NSInteger *outStatus, NSString **outErr) {
    if (outStatus) *outStatus = 0;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (outErr) *outErr = @"Invalid URL";
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = timeoutSec;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (jsonBody) {
        NSError *je = nil;
        NSData *body = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:&je];
        if (!body) {
            if (outErr) *outErr = je.localizedDescription ?: @"JSON encode failed";
            return nil;
        }
        req.HTTPBody = body;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = timeoutSec;
    cfg.timeoutIntervalForResource = timeoutSec + 5.0;
    cfg.connectionProxyDictionary = @{}; // never proxy localhost
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *respData = nil;
    __block NSURLResponse *respObj = nil;
    __block NSError *respErr = nil;

    NSURLSessionDataTask *task = [sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        respData = data;
        respObj = response;
        respErr = error;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [sess finishTasksAndInvalidate];

    if ([respObj isKindOfClass:[NSHTTPURLResponse class]]) {
        if (outStatus) *outStatus = ((NSHTTPURLResponse *)respObj).statusCode;
    }
    if (respErr) {
        if (outErr) *outErr = respErr.localizedDescription ?: @"HTTP request error";
        return nil;
    }
    if (!respData || respData.length == 0) {
        if (outErr) *outErr = @"Empty response";
        return nil;
    }
    NSError *pe = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&pe];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        NSString *raw = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"";
        if (outErr) *outErr = [NSString stringWithFormat:@"Non-JSON response: %@", [raw substringToIndex:MIN(raw.length, 200)]];
        return nil;
    }
    return (NSDictionary *)parsed;
}

static NSString *sanitizeHeaderVal(NSString *s) {
    if (!s) return @"";
    NSString *r = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"_"];
    r = [r stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    r = [r stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    return r;
}

static BOOL appendUTF8(NSFileHandle *fh, NSString *s, NSString **outErr) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return YES;
    @try {
        [fh writeData:d];
        return YES;
    } @catch (NSException *ex) {
        if (outErr) *outErr = ex.reason ?: @"Write failed";
        return NO;
    }
}

// Build strict RFC-7578 multipart/form-data file on disk (no trailing semicolon, zero RAM bloat)
static BOOL buildMultipartFile(NSString *outPath,
                               NSString *boundary,
                               NSArray<NSArray<NSString *> *> *textFields,
                               NSString *fileFieldName,
                               NSString *srcFilePath,
                               NSString *uploadFileName,
                               uint64_t *outTotalSize,
                               NSString **outErr) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:outPath error:nil];
    if (![fm createFileAtPath:outPath contents:nil attributes:nil]) {
        if (outErr) *outErr = @"Cannot create temp multipart file";
        return NO;
    }
    NSFileHandle *outFH = [NSFileHandle fileHandleForWritingAtPath:outPath];
    NSFileHandle *inFH  = [NSFileHandle fileHandleForReadingAtPath:srcFilePath];
    if (!outFH || !inFH) {
        [outFH closeFile];
        [inFH closeFile];
        if (outErr) *outErr = !inFH ? @"Cannot open source .ghostpair file" : @"Cannot open temp file for writing";
        return NO;
    }

    BOOL ok = YES;
    for (NSArray<NSString *> *kv in textFields) {
        NSString *k = sanitizeHeaderVal(kv[0]);
        NSString *v = kv[1] ?: @"";
        NSString *part = [NSString stringWithFormat:
            @"--%@\r\n"
            @"Content-Disposition: form-data; name=\"%@\"\r\n"
            @"\r\n"
            @"%@\r\n", boundary, k, v];
        if (!appendUTF8(outFH, part, outErr)) { ok = NO; break; }
    }

    if (ok) {
        NSString *hdr = [NSString stringWithFormat:
            @"--%@\r\n"
            @"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n"
            @"Content-Type: application/octet-stream\r\n"
            @"\r\n",
            boundary, sanitizeHeaderVal(fileFieldName), sanitizeHeaderVal(uploadFileName)];
        ok = appendUTF8(outFH, hdr, outErr);
    }

    if (ok) {
        while (true) {
            @autoreleasepool {
                NSData *chunk = [inFH readDataOfLength:65536];
                if (!chunk || chunk.length == 0) break;
                @try {
                    [outFH writeData:chunk];
                } @catch (NSException *ex) {
                    if (outErr) *outErr = ex.reason ?: @"Write chunk failed";
                    ok = NO;
                    break;
                }
            }
        }
    }

    if (ok) {
        NSString *tail = [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary];
        ok = appendUTF8(outFH, tail, outErr);
    }

    [inFH closeFile];
    [outFH closeFile];

    if (ok && outTotalSize) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:outPath error:nil];
        *outTotalSize = [attrs fileSize];
    }
    return ok;
}

static void runBackupUploadJob(NSMutableDictionary *job, NSDictionary *params) {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];

        NSString *uploadURL = [params[@"url"] isKindOfClass:[NSString class]] && [params[@"url"] length]
            ? params[@"url"] : kDefaultUploadURL;
        NSString *apiKey = [params[@"api_key"] isKindOfClass:[NSString class]] ? params[@"api_key"] : @"";
        NSString *password = [params[@"password"] isKindOfClass:[NSString class]] ? params[@"password"] : @"";
        NSString *username = [params[@"username"] isKindOfClass:[NSString class]] ? params[@"username"] : @"";
        NSString *twofa = [params[@"2fa"] isKindOfClass:[NSString class]] ? params[@"2fa"] : @"";
        NSString *kind = [params[@"kind"] isKindOfClass:[NSString class]] && [params[@"kind"] length]
            ? params[@"kind"] : @"container";

        NSString *selector = [params[@"selector"] isKindOfClass:[NSString class]] && [params[@"selector"] length]
            ? params[@"selector"] : @"both";
        NSString *format = [params[@"format"] isKindOfClass:[NSString class]] && [params[@"format"] length]
            ? params[@"format"] : @"ghostpair";
        NSString *targetContainer = [params[@"target_container"] isKindOfClass:[NSString class]] && [params[@"target_container"] length]
            ? params[@"target_container"] : @"taoacc";
        NSString *targetIg = [params[@"target_ig"] isKindOfClass:[NSString class]] && [params[@"target_ig"] length]
            ? params[@"target_ig"] : targetContainer;
        NSString *targetTh = [params[@"target_th"] isKindOfClass:[NSString class]] && [params[@"target_th"] length]
            ? params[@"target_th"] : targetContainer;

        NSString *explicitFilePath = [params[@"file_path"] isKindOfClass:[NSString class]] ? params[@"file_path"] : @"";
        BOOL deleteAfter = (params[@"delete_after"] != nil) ? [params[@"delete_after"] boolValue] : (explicitFilePath.length == 0);
        BOOL dryRun = [params[@"dry_run"] boolValue];
        double backupTimeout = [params[@"backup_timeout"] doubleValue] > 0 ? [params[@"backup_timeout"] doubleValue] : 180.0;
        double uploadTimeout = [params[@"upload_timeout"] doubleValue] > 0 ? [params[@"upload_timeout"] doubleValue] : 120.0;

        NSString *filePath = nil;
        NSString *fileName = nil;
        uint64_t fileSize = 0;

        // ===== STEP 1: BACKUP CRANE (or use existing file_path) =====
        if (explicitFilePath.length > 0) {
            if (![fm fileExistsAtPath:explicitFilePath]) {
                jobUpdate(job, @"error", @"File không tồn tại trên iPhone", @{
                    @"ok": @NO, @"state": @"error",
                    @"error": [NSString stringWithFormat:@"file_path not found: %@", explicitFilePath]
                });
                return;
            }
            filePath = explicitFilePath;
            fileName = explicitFilePath.lastPathComponent;
            fileSize = [[fm attributesOfItemAtPath:filePath error:nil] fileSize];
            jobUpdate(job, @"uploading",
                      [NSString stringWithFormat:@"Dùng file sẵn có: %@ (%llu bytes)", fileName, fileSize],
                      @{@"file_path": filePath, @"file_name": fileName, @"file_size": @(fileSize)});
        } else {
            double backupStart = nowMono();
            jobUpdate(job, @"backup_start",
                      [NSString stringWithFormat:@"Bắt đầu backup Crane (%@, container=%@)...", selector, targetContainer],
                      nil);

            NSDictionary *bReq = @{
                @"selector": selector,
                @"format": format,
                @"target_container": targetContainer,
                @"target_ig": targetIg,
                @"target_th": targetTh
            };
            NSInteger st = 0;
            NSString *bErr = nil;
            NSDictionary *bResp = localJSONRequest(@"POST", [kRestoreBaseURL stringByAppendingString:@"/backup-now"], bReq, 30.0, &st, &bErr);
            if (!bResp || ![bResp[@"success"] boolValue]) {
                NSString *msg = bResp[@"error"] ?: bErr ?: [NSString stringWithFormat:@"backup-now failed (HTTP %ld)", (long)st];
                jobUpdate(job, @"error", [NSString stringWithFormat:@"Lỗi gọi backup-now: %@", msg], @{
                    @"ok": @NO, @"state": @"error", @"error": msg
                });
                return;
            }
            NSString *bJobId = [bResp[@"job_id"] isKindOfClass:[NSString class]] ? bResp[@"job_id"] : @"";
            if (!bJobId.length) {
                jobUpdate(job, @"error", @"backup-now không trả về job_id", @{
                    @"ok": @NO, @"state": @"error", @"error": @"Missing backup job_id"
                });
                return;
            }
            jobUpdate(job, @"backing_up",
                      [NSString stringWithFormat:@"Đang backup Crane (job_id=%@)...", bJobId],
                      @{@"backup_job_id": bJobId});

            NSString *lastSubStage = @"";
            NSString *encId = [bJobId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            NSString *pollURL = [NSString stringWithFormat:@"%@/status?job_id=%@", kRestoreBaseURL, encId];

            BOOL backupDone = NO;
            NSDictionary *finalBackupJob = nil;
            while ((nowMono() - backupStart) < backupTimeout) {
                usleep(1500000); // 1.5s
                NSInteger pst = 0;
                NSString *perr = nil;
                NSDictionary *pResp = localJSONRequest(@"GET", pollURL, nil, 15.0, &pst, &perr);
                if (!pResp) continue;
                NSDictionary *bj = [pResp[@"job"] isKindOfClass:[NSDictionary class]] ? pResp[@"job"] : nil;
                if (!bj) continue;

                NSString *bStage = [bj[@"stage"] isKindOfClass:[NSString class]] ? bj[@"stage"] : @"";
                BOOL bRunning = [bj[@"running"] boolValue] || [bStage isEqualToString:@"queued"] || [bStage isEqualToString:@"starting"];
                double bElapsed = [bj[@"elapsed_s"] doubleValue];

                @synchronized(g_jobs) {
                    job[@"backup_stage"] = bStage;
                    job[@"backup_elapsed_s"] = @(round(bElapsed * 100.0) / 100.0);
                    job[@"elapsed_s"] = @(round((nowMono() - [job[@"started_at"] doubleValue]) * 100.0) / 100.0);
                }

                if (bStage.length && ![bStage isEqualToString:lastSubStage] && bRunning) {
                    lastSubStage = bStage;
                    jobUpdate(job, @"backing_up",
                              [NSString stringWithFormat:@"Backup stage: %@ (%.1fs)", bStage, bElapsed],
                              nil);
                }
                if (!bRunning) {
                    backupDone = YES;
                    finalBackupJob = bj;
                    break;
                }
            }

            if (!backupDone || !finalBackupJob) {
                NSString *msg = [NSString stringWithFormat:@"Backup Crane timeout sau %.0fs", backupTimeout];
                jobUpdate(job, @"error", msg, @{@"ok": @NO, @"state": @"error", @"error": msg});
                return;
            }
            if (![finalBackupJob[@"success"] boolValue]) {
                NSString *msg = [finalBackupJob[@"error"] isKindOfClass:[NSString class]] && [finalBackupJob[@"error"] length]
                    ? finalBackupJob[@"error"] : @"Backup Crane thất bại";
                jobUpdate(job, @"error", [NSString stringWithFormat:@"Backup thất bại: %@", msg], @{
                    @"ok": @NO, @"state": @"error", @"error": msg
                });
                return;
            }

            filePath = [finalBackupJob[@"output_path"] isKindOfClass:[NSString class]] ? finalBackupJob[@"output_path"] : @"";
            fileName = [finalBackupJob[@"output_filename"] isKindOfClass:[NSString class]] && [finalBackupJob[@"output_filename"] length]
                ? finalBackupJob[@"output_filename"] : filePath.lastPathComponent;
            if (!username.length && [finalBackupJob[@"username"] isKindOfClass:[NSString class]] && [finalBackupJob[@"username"] length]) {
                username = finalBackupJob[@"username"];
            }
            if (!filePath.length || ![fm fileExistsAtPath:filePath]) {
                NSString *msg = [NSString stringWithFormat:@"Không tìm thấy file backup: %@", filePath ?: @"(empty)"];
                jobUpdate(job, @"error", msg, @{@"ok": @NO, @"state": @"error", @"error": msg});
                return;
            }
            fileSize = [[fm attributesOfItemAtPath:filePath error:nil] fileSize];
            double bDur = round((nowMono() - backupStart) * 100.0) / 100.0;
            jobUpdate(job, @"uploading",
                      [NSString stringWithFormat:@"Backup xong trong %.1fs: %@ (%.2f MB)", bDur, fileName, (double)fileSize / (1024.0 * 1024.0)],
                      @{
                          @"backup_elapsed_s": @(bDur),
                          @"file_path": filePath,
                          @"file_name": fileName,
                          @"file_size": @(fileSize),
                          @"username": username ?: @""
                      });
        }

        // ===== STEP 2: BUILD STRICT RFC-7578 MULTIPART & UPLOAD =====
        NSString *boundary = [NSString stringWithFormat:@"TapCoreBoundary%@",
                              [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""]];
        NSMutableArray<NSArray<NSString *> *> *fields = [NSMutableArray array];
        [fields addObject:@[@"password", password]];
        if (username.length > 0) [fields addObject:@[@"username", username]];
        if (twofa.length > 0)    [fields addObject:@[@"2fa", twofa]];
        if (kind.length > 0)     [fields addObject:@[@"kind", kind]];

        NSString *tmpMultipart = [NSString stringWithFormat:@"/tmp/tapcore_upload_%@.multipart", job[@"job_id"]];
        uint64_t multipartSize = 0;
        NSString *buildErr = nil;
        if (!buildMultipartFile(tmpMultipart, boundary, fields, @"crane", filePath, fileName, &multipartSize, &buildErr)) {
            [fm removeItemAtPath:tmpMultipart error:nil];
            NSString *msg = [NSString stringWithFormat:@"Lỗi đóng gói multipart: %@", buildErr ?: @"unknown"];
            jobUpdate(job, @"error", msg, @{@"ok": @NO, @"state": @"error", @"error": msg});
            return;
        }

        if (dryRun) {
            [fm removeItemAtPath:tmpMultipart error:nil];
            jobUpdate(job, @"done",
                      [NSString stringWithFormat:@"DRY RUN OK: sẵn sàng upload %@ (%llu bytes, multipart=%llu bytes) tới %@",
                       fileName, fileSize, multipartSize, uploadURL],
                      @{
                          @"ok": @YES,
                          @"state": @"finished",
                          @"dry_run": @YES,
                          @"multipart_size": @(multipartSize),
                          @"deleted": @NO
                      });
            return;
        }

        double upStart = nowMono();
        jobUpdate(job, @"uploading",
                  [NSString stringWithFormat:@"Đang upload %@ (%.2f MB) lên %@...",
                   fileName, (double)fileSize / (1024.0 * 1024.0), uploadURL],
                  @{@"upload_url": uploadURL});

        NSURL *targetURL = [NSURL URLWithString:uploadURL];
        if (!targetURL) {
            [fm removeItemAtPath:tmpMultipart error:nil];
            jobUpdate(job, @"error", @"URL upload không hợp lệ", @{
                @"ok": @NO, @"state": @"error", @"error": @"Invalid upload URL"
            });
            return;
        }

        NSMutableURLRequest *upReq = [NSMutableURLRequest requestWithURL:targetURL];
        upReq.HTTPMethod = @"POST";
        upReq.timeoutInterval = uploadTimeout;
        if (apiKey.length > 0) {
            [upReq setValue:apiKey forHTTPHeaderField:@"X-API-Key"];
        }
        [upReq setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
     forHTTPHeaderField:@"Content-Type"];
        [upReq setValue:[NSString stringWithFormat:@"%llu", multipartSize]
     forHTTPHeaderField:@"Content-Length"];
        [upReq setValue:@"application/json, */*" forHTTPHeaderField:@"Accept"];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = uploadTimeout;
        cfg.timeoutIntervalForResource = uploadTimeout + 15.0;
        NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *upData = nil;
        __block NSURLResponse *upResp = nil;
        __block NSError *upErr = nil;

        NSURLSessionUploadTask *upTask = [sess uploadTaskWithRequest:upReq
                                                            fromFile:[NSURL fileURLWithPath:tmpMultipart]
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            upData = data;
            upResp = response;
            upErr = error;
            dispatch_semaphore_signal(sem);
        }];
        [upTask resume];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        [sess finishTasksAndInvalidate];
        [fm removeItemAtPath:tmpMultipart error:nil];

        double upDur = round((nowMono() - upStart) * 100.0) / 100.0;
        NSInteger httpStatus = [upResp isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)upResp).statusCode : 0;
        NSString *rawResp = upData ? ([[NSString alloc] initWithData:upData encoding:NSUTF8StringEncoding] ?: @"") : @"";
        id parsedResp = nil;
        if (upData.length > 0) {
            parsedResp = [NSJSONSerialization JSONObjectWithData:upData options:0 error:nil];
        }

        if (upErr) {
            NSString *msg = upErr.localizedDescription ?: @"Upload network error";
            jobUpdate(job, @"error", [NSString stringWithFormat:@"Lỗi mạng khi upload (%.1fs): %@", upDur, msg], @{
                @"ok": @NO,
                @"state": @"error",
                @"upload_http_status": @(httpStatus),
                @"upload_elapsed_s": @(upDur),
                @"upload_raw": rawResp,
                @"error": msg
            });
            return;
        }

        BOOL serverOk = (httpStatus >= 200 && httpStatus < 300);
        if (serverOk && [parsedResp isKindOfClass:[NSDictionary class]] && parsedResp[@"ok"] != nil) {
            serverOk = [parsedResp[@"ok"] boolValue];
        }

        if (!serverOk) {
            NSString *srvErr = nil;
            if ([parsedResp isKindOfClass:[NSDictionary class]]) {
                srvErr = [parsedResp[@"error"] isKindOfClass:[NSString class]] ? parsedResp[@"error"] : nil;
            }
            if (!srvErr.length) {
                srvErr = rawResp.length ? [rawResp substringToIndex:MIN(rawResp.length, 300)]
                                        : [NSString stringWithFormat:@"HTTP %ld", (long)httpStatus];
            }
            NSMutableDictionary *ex = [@{
                @"ok": @NO,
                @"state": @"error",
                @"upload_http_status": @(httpStatus),
                @"upload_elapsed_s": @(upDur),
                @"upload_raw": rawResp,
                @"error": srvErr
            } mutableCopy];
            if (parsedResp) ex[@"upload_response"] = parsedResp;
            jobUpdate(job, @"error",
                      [NSString stringWithFormat:@"Server trả lỗi HTTP %ld (%.1fs): %@", (long)httpStatus, upDur, srvErr],
                      ex);
            return;
        }

        // ===== STEP 3: CLEANUP TEMP .ghostpair =====
        BOOL deleted = NO;
        if (deleteAfter && filePath.length > 0) {
            jobUpdate(job, @"cleanup", [NSString stringWithFormat:@"Đang xóa file tạm %@...", fileName], nil);
            deleted = [fm removeItemAtPath:filePath error:nil];
        }

        NSMutableDictionary *doneExtra = [@{
            @"ok": @YES,
            @"state": @"finished",
            @"upload_http_status": @(httpStatus),
            @"upload_elapsed_s": @(upDur),
            @"upload_raw": rawResp,
            @"deleted": @(deleted),
            @"error": @""
        } mutableCopy];
        if (parsedResp) doneExtra[@"upload_response"] = parsedResp;

        NSString *doneMsg = [NSString stringWithFormat:@"Upload thành công HTTP %ld trong %.1fs%@",
                             (long)httpStatus, upDur, deleted ? @" (đã xóa file tạm)" : @""];
        jobUpdate(job, @"done", doneMsg, doneExtra);
    }
}

NSDictionary *tapcore_backup_upload_start(NSDictionary *params, BOOL waitForCompletion) {
    ensureStore();
    if (![params isKindOfClass:[NSDictionary class]]) {
        return @{@"ok": @NO, @"error": @"JSON body required"};
    }
    NSString *password = [params[@"password"] isKindOfClass:[NSString class]] ? params[@"password"] : @"";
    BOOL dryRun = [params[@"dry_run"] boolValue];
    NSString *apiKey = [params[@"api_key"] isKindOfClass:[NSString class]] ? params[@"api_key"] : @"";
    if (!password.length) {
        return @{@"ok": @NO, @"error": @"password is required"};
    }
    if (!dryRun && !apiKey.length) {
        return @{@"ok": @NO, @"error": @"api_key is required"};
    }

    NSMutableDictionary *job = nil;
    NSString *jobId = nil;
    @synchronized(g_jobs) {
        g_jobSeq++;
        jobId = [NSString stringWithFormat:@"bu_%lld_%llu", (long long)nowMono(), g_jobSeq];
        job = [@{
            @"ok": @NO,
            @"job_id": jobId,
            @"state": @"running",
            @"stage": @"init",
            @"message": @"Đang khởi tạo...",
            @"started_at": @(nowMono()),
            @"elapsed_s": @(0.0),
            @"backup_job_id": @"",
            @"backup_stage": @"",
            @"backup_elapsed_s": @(0.0),
            @"file_path": @"",
            @"file_name": @"",
            @"file_size": @(0),
            @"username": [params[@"username"] isKindOfClass:[NSString class]] ? params[@"username"] : @"",
            @"upload_url": [params[@"url"] isKindOfClass:[NSString class]] && [params[@"url"] length] ? params[@"url"] : kDefaultUploadURL,
            @"upload_http_status": @(0),
            @"upload_elapsed_s": @(0.0),
            @"deleted": @NO,
            @"dry_run": @(dryRun),
            @"error": @"",
            @"steps": [NSMutableArray array]
        } mutableCopy];
        g_jobs[jobId] = job;
        g_latestJobId = jobId;
        [g_jobOrder addObject:jobId];
        while (g_jobOrder.count > 20) {
            NSString *oldId = g_jobOrder.firstObject;
            [g_jobOrder removeObjectAtIndex:0];
            [g_jobs removeObjectForKey:oldId];
        }
    }

    NSDictionary *paramsCopy = [params copy];
    if (waitForCompletion) {
        runBackupUploadJob(job, paramsCopy);
        return snapshotJob(job);
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        runBackupUploadJob(job, paramsCopy);
    });
    return @{
        @"ok": @YES,
        @"job_id": jobId,
        @"state": @"running",
        @"stage": @"init",
        @"message": @"Đã bắt đầu job backup & upload"
    };
}

NSDictionary *tapcore_backup_upload_status(NSString *jobId) {
    ensureStore();
    NSMutableDictionary *job = nil;
    @synchronized(g_jobs) {
        NSString *key = (jobId.length > 0) ? jobId : g_latestJobId;
        if (key.length > 0) job = g_jobs[key];
    }
    if (!job) {
        return @{@"ok": @NO, @"state": @"not_found", @"error": @"No backup_upload job found"};
    }
    return snapshotJob(job);
}
