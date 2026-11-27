#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <poll.h>
#import <signal.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <sys/wait.h>
#import <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "tapcore.h"

static double monotonicSec(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

@interface TCHttpDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, assign) BOOL followRedirects;
@property (nonatomic, assign) BOOL insecureTLS;
@end

@implementation TCHttpDelegate
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session; (void)task; (void)response;
    completionHandler(self.followRedirects ? request : nil);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    (void)session; (void)task;
    if (self.insecureTLS &&
        [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        challenge.protectionSpace.serverTrust != NULL) {
        NSURLCredential *cred = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

static NSDictionary *parseRawHeaders(NSString *raw) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!raw.length) return d;
    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!t.length) continue;
        NSRange colon = [t rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) continue;
        NSString *k = [[t substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [[t substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (k.length) d[k] = v;
    }
    return d;
}

static NSString *resolveHostToIPv4(NSString *host) {
    if (!host.length) return host;
    struct in_addr addr;
    if (inet_pton(AF_INET, host.UTF8String, &addr) == 1) return host;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &res) == 0 && res) {
        char buf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
            freeaddrinfo(res);
            return [NSString stringWithUTF8String:buf];
        }
        freeaddrinfo(res);
    }
    return host;
}

static NSDictionary *runCurlRequest(NSString *curlBin,
                                    NSString *url,
                                    NSString *method,
                                    NSDictionary<NSString *, NSString *> *headers,
                                    NSData *bodyData,
                                    double timeoutSec,
                                    BOOL followRedirects,
                                    BOOL insecureTLS,
                                    NSDictionary *proxy) {
    char hdrTmpl[] = "/tmp/tc_hdr_XXXXXX";
    int hfd = mkstemp(hdrTmpl);
    if (hfd < 0) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"mkstemp failed"};
    }
    close(hfd);
    NSString *hdrPath = [NSString stringWithUTF8String:hdrTmpl];

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    [args addObject:curlBin];
    [args addObject:@"-sS"];
    [args addObject:@"--connect-timeout"];
    [args addObject:[NSString stringWithFormat:@"%.0f", fmax(3.0, fmin(timeoutSec, 20.0))]];
    [args addObject:@"--max-time"];
    [args addObject:[NSString stringWithFormat:@"%.0f", fmax(1.0, timeoutSec)]];
    [args addObject:@"-D"];
    [args addObject:hdrPath];
    [args addObject:@"-X"];
    [args addObject:method];
    if (followRedirects) [args addObject:@"-L"];
    if (insecureTLS) [args addObject:@"-k"];

    if (proxy) {
        NSString *ptype = [[proxy[@"type"] description] lowercaseString] ?: @"http";
        NSString *host = resolveHostToIPv4(proxy[@"host"] ?: @"");
        int port = [proxy[@"port"] intValue];
        NSString *user = proxy[@"user"] ?: @"";
        NSString *pass = proxy[@"pass"] ?: @"";
        if (host.length && port > 0) {
            if ([ptype hasPrefix:@"socks"]) {
                [args addObject:@"--socks5-hostname"];
                [args addObject:[NSString stringWithFormat:@"%@:%d", host, port]];
            } else {
                [args addObject:@"-x"];
                [args addObject:[NSString stringWithFormat:@"http://%@:%d", host, port]];
            }
            if (user.length || pass.length) {
                [args addObject:@"--proxy-user"];
                [args addObject:[NSString stringWithFormat:@"%@:%@", user, pass]];
            }
        }
    }

    for (NSString *k in headers) {
        [args addObject:@"-H"];
        [args addObject:[NSString stringWithFormat:@"%@: %@", k, headers[k]]];
    }

    char bodyTmpl[] = "/tmp/tc_body_XXXXXX";
    NSString *bodyPath = nil;
    if (bodyData && bodyData.length > 0) {
        int bfd = mkstemp(bodyTmpl);
        if (bfd >= 0) {
            const uint8_t *p = bodyData.bytes;
            size_t rem = bodyData.length;
            while (rem > 0) {
                ssize_t w = write(bfd, p, rem);
                if (w <= 0) break;
                p += w;
                rem -= (size_t)w;
            }
            close(bfd);
            bodyPath = [NSString stringWithUTF8String:bodyTmpl];
            [args addObject:@"--data-binary"];
            [args addObject:[@"@" stringByAppendingString:bodyPath]];
        }
    }

    [args addObject:url];

    int outPipe[2], errPipe[2];
    if (pipe(outPipe) != 0) {
        unlink(hdrPath.UTF8String);
        if (bodyPath) unlink(bodyPath.UTF8String);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"pipe failed"};
    }
    if (pipe(errPipe) != 0) {
        close(outPipe[0]); close(outPipe[1]);
        unlink(hdrPath.UTF8String);
        if (bodyPath) unlink(bodyPath.UTF8String);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"pipe failed"};
    }

    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i] = strdup(args[i].UTF8String);
    }

    pid_t pid = fork();
    if (pid == 0) {
        dup2(outPipe[1], STDOUT_FILENO);
        dup2(errPipe[1], STDERR_FILENO);
        close(outPipe[0]); close(outPipe[1]);
        close(errPipe[0]); close(errPipe[1]);
        setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin", 1);
        execv(curlBin.UTF8String, argv);
        _exit(127);
    }

    for (NSUInteger i = 0; i < args.count; i++) free(argv[i]);
    free(argv);
    close(outPipe[1]);
    close(errPipe[1]);

    if (pid < 0) {
        close(outPipe[0]); close(errPipe[0]);
        unlink(hdrPath.UTF8String);
        if (bodyPath) unlink(bodyPath.UTF8String);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"fork failed"};
    }

    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(errPipe[0], F_SETFL, O_NONBLOCK);

    NSMutableData *outData = [NSMutableData data];
    NSMutableData *errData = [NSMutableData data];
    BOOL outOpen = YES, errOpen = YES, stopped = NO;
    double deadline = monotonicSec() + fmax(2.0, timeoutSec + 5.0);
    uint8_t buf[8192];

    while (outOpen || errOpen) {
        if (tapcore_script_should_stop()) {
            stopped = YES;
            kill(pid, SIGKILL);
            break;
        }
        if (monotonicSec() > deadline) {
            kill(pid, SIGKILL);
            break;
        }
        struct pollfd pfds[2];
        int nfds = 0;
        int outIdx = -1, errIdx = -1;
        if (outOpen) { outIdx = nfds; pfds[nfds].fd = outPipe[0]; pfds[nfds].events = POLLIN; nfds++; }
        if (errOpen) { errIdx = nfds; pfds[nfds].fd = errPipe[0]; pfds[nfds].events = POLLIN; nfds++; }
        int pr = poll(pfds, (nfds_t)nfds, 50);
        if (pr > 0) {
            if (outIdx >= 0 && (pfds[outIdx].revents & (POLLIN | POLLHUP | POLLERR))) {
                ssize_t r = read(outPipe[0], buf, sizeof(buf));
                if (r > 0) [outData appendBytes:buf length:(size_t)r];
                else if (r == 0 || (errno != EAGAIN && errno != EINTR)) outOpen = NO;
            }
            if (errIdx >= 0 && (pfds[errIdx].revents & (POLLIN | POLLHUP | POLLERR))) {
                ssize_t r = read(errPipe[0], buf, sizeof(buf));
                if (r > 0) [errData appendBytes:buf length:(size_t)r];
                else if (r == 0 || (errno != EAGAIN && errno != EINTR)) errOpen = NO;
            }
        }
    }

    close(outPipe[0]);
    close(errPipe[0]);
    int wstatus = 0;
    waitpid(pid, &wstatus, 0);

    NSData *hdrRaw = [NSData dataWithContentsOfFile:hdrPath];
    unlink(hdrPath.UTF8String);
    if (bodyPath) unlink(bodyPath.UTF8String);

    if (stopped) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Stopped"};
    }

    int exitCode = WIFEXITED(wstatus) ? WEXITSTATUS(wstatus) : -1;
    int httpStatus = 0;
    NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];
    if (hdrRaw.length > 0) {
        NSString *hs = [[NSString alloc] initWithData:hdrRaw encoding:NSISOLatin1StringEncoding] ?: @"";
        NSArray<NSString *> *blocks = [hs componentsSeparatedByString:@"\r\n\r\n"];
        NSString *lastBlock = @"";
        for (NSString *b in blocks) {
            NSString *tr = [b stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([tr hasPrefix:@"HTTP/"]) lastBlock = tr;
        }
        NSArray<NSString *> *hlines = [lastBlock componentsSeparatedByString:@"\r\n"];
        if (hlines.count > 0) {
            NSArray<NSString *> *parts = [hlines[0] componentsSeparatedByString:@" "];
            if (parts.count >= 2) httpStatus = [parts[1] intValue];
            for (NSUInteger i = 1; i < hlines.count; i++) {
                NSRange c = [hlines[i] rangeOfString:@":"];
                if (c.location == NSNotFound) continue;
                NSString *k = [[hlines[i] substringToIndex:c.location] lowercaseString];
                NSString *v = [[hlines[i] substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (k.length) respHeaders[k] = v;
            }
        }
    }

    if (exitCode != 0 && httpStatus == 0) {
        NSString *es = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"curl failed";
        es = [es stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"headers": respHeaders,
                 @"error": es.length ? es : [NSString stringWithFormat:@"curl exit %d", exitCode]};
    }

    return @{
        @"ok": @(httpStatus > 0),
        @"status": @(httpStatus),
        @"body_data": outData,
        @"headers": respHeaders
    };
}

// Pure POSIX SOCKS5 (RFC 1928 + RFC 1929 user/pass) fallback for plain HTTP when curl is unavailable
static NSDictionary *runSocks5PlainHttp(NSString *urlStr,
                                        NSString *method,
                                        NSDictionary<NSString *, NSString *> *headers,
                                        NSData *bodyData,
                                        double timeoutSec,
                                        NSDictionary *proxy) {
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u || !u.host.length) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Invalid URL"};
    }
    NSString *pxHost = proxy[@"host"] ?: @"";
    int pxPort = [proxy[@"port"] intValue];
    NSString *pxUser = proxy[@"user"] ?: @"";
    NSString *pxPass = proxy[@"pass"] ?: @"";

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char portBuf[16];
    snprintf(portBuf, sizeof(portBuf), "%d", pxPort);
    if (getaddrinfo(pxHost.UTF8String, portBuf, &hints, &res) != 0 || !res) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Proxy DNS failed"};
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"socket failed"};
    }
    struct timeval tv;
    int ts = (int)fmax(2.0, timeoutSec);
    tv.tv_sec = ts; tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        close(fd);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Proxy connect failed"};
    }
    freeaddrinfo(res);

    BOOL hasAuth = (pxUser.length > 0 || pxPass.length > 0);
    uint8_t greet[4] = {0x05, hasAuth ? (uint8_t)2 : (uint8_t)1, 0x00, 0x02};
    if (send(fd, greet, hasAuth ? 4 : 3, 0) <= 0) {
        close(fd);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 greet send failed"};
    }
    uint8_t gresp[2] = {0};
    if (recv(fd, gresp, 2, MSG_WAITALL) != 2 || gresp[0] != 0x05 || gresp[1] == 0xFF) {
        close(fd);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 greet rejected"};
    }
    if (gresp[1] == 0x02) {
        const char *us = pxUser.UTF8String;
        const char *ps = pxPass.UTF8String;
        size_t ul = strlen(us), pl = strlen(ps);
        if (ul > 255 || pl > 255) { close(fd); return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 creds too long"}; }
        NSMutableData *auth = [NSMutableData data];
        uint8_t v = 0x01, ulen = (uint8_t)ul, plen = (uint8_t)pl;
        [auth appendBytes:&v length:1];
        [auth appendBytes:&ulen length:1];
        [auth appendBytes:us length:ul];
        [auth appendBytes:&plen length:1];
        [auth appendBytes:ps length:pl];
        if (send(fd, auth.bytes, auth.length, 0) != (ssize_t)auth.length) {
            close(fd);
            return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 auth send failed"};
        }
        uint8_t aresp[2] = {0};
        if (recv(fd, aresp, 2, MSG_WAITALL) != 2 || aresp[1] != 0x00) {
            close(fd);
            return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 auth failed"};
        }
    }

    const char *thost = u.host.UTF8String;
    size_t thlen = strlen(thost);
    uint16_t tport = (uint16_t)(u.port ? [u.port intValue] : 80);
    NSMutableData *creq = [NSMutableData data];
    uint8_t chdr[5] = {0x05, 0x01, 0x00, 0x03, (uint8_t)thlen};
    [creq appendBytes:chdr length:5];
    [creq appendBytes:thost length:thlen];
    uint8_t pbytes[2] = {(uint8_t)(tport >> 8), (uint8_t)(tport & 0xFF)};
    [creq appendBytes:pbytes length:2];
    if (send(fd, creq.bytes, creq.length, 0) != (ssize_t)creq.length) {
        close(fd);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 connect send failed"};
    }
    uint8_t cresp[4] = {0};
    if (recv(fd, cresp, 4, MSG_WAITALL) != 4 || cresp[1] != 0x00) {
        close(fd);
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"SOCKS5 connect rejected"};
    }
    size_t skipLen = 0;
    if (cresp[3] == 0x01) skipLen = 4 + 2;
    else if (cresp[3] == 0x04) skipLen = 16 + 2;
    else if (cresp[3] == 0x03) {
        uint8_t dl = 0;
        if (recv(fd, &dl, 1, MSG_WAITALL) == 1) skipLen = (size_t)dl + 2;
    }
    if (skipLen > 0) {
        uint8_t dummy[300];
        recv(fd, dummy, skipLen < sizeof(dummy) ? skipLen : sizeof(dummy), MSG_WAITALL);
    }

    NSString *path = u.path.length ? u.path : @"/";
    if (u.query.length) path = [NSString stringWithFormat:@"%@?%@", path, u.query];
    NSMutableString *req = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\n",
                            method, path, u.port ? [NSString stringWithFormat:@"%@:%@", u.host, u.port] : u.host];
    for (NSString *k in headers) {
        [req appendFormat:@"%@: %@\r\n", k, headers[k]];
    }
    if (bodyData.length > 0) {
        [req appendFormat:@"Content-Length: %lu\r\n", (unsigned long)bodyData.length];
    }
    [req appendString:@"\r\n"];

    NSData *reqHdr = [req dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, reqHdr.bytes, reqHdr.length, 0);
    if (bodyData.length > 0) send(fd, bodyData.bytes, bodyData.length, 0);

    NSMutableData *resp = [NSMutableData data];
    uint8_t buf[4096];
    for (;;) {
        if (tapcore_script_should_stop()) { close(fd); return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Stopped"}; }
        ssize_t r = recv(fd, buf, sizeof(buf), 0);
        if (r <= 0) break;
        [resp appendBytes:buf length:(size_t)r];
    }
    close(fd);

    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange split = [resp rangeOfData:sep options:0 range:NSMakeRange(0, resp.length)];
    if (split.location == NSNotFound) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Malformed HTTP response"};
    }
    NSString *hs = [[NSString alloc] initWithBytes:resp.bytes length:split.location encoding:NSISOLatin1StringEncoding] ?: @"";
    NSArray<NSString *> *hlines = [hs componentsSeparatedByString:@"\r\n"];
    int status = 0;
    NSMutableDictionary *rh = [NSMutableDictionary dictionary];
    if (hlines.count > 0) {
        NSArray *p = [hlines[0] componentsSeparatedByString:@" "];
        if (p.count >= 2) status = [p[1] intValue];
        for (NSUInteger i = 1; i < hlines.count; i++) {
            NSRange c = [hlines[i] rangeOfString:@":"];
            if (c.location == NSNotFound) continue;
            rh[[[hlines[i] substringToIndex:c.location] lowercaseString]] =
                [[hlines[i] substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    NSData *bodyOut = [resp subdataWithRange:NSMakeRange(split.location + 4, resp.length - split.location - 4)];
    return @{@"ok": @(status > 0), @"status": @(status), @"body_data": bodyOut, @"headers": rh};
}

static NSDictionary *runNSURLSessionRequest(NSString *urlStr,
                                            NSString *method,
                                            NSDictionary<NSString *, NSString *> *headers,
                                            NSData *bodyData,
                                            double timeoutSec,
                                            BOOL followRedirects,
                                            BOOL insecureTLS,
                                            NSDictionary *proxy) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Invalid URL"};
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = fmax(1.0, timeoutSec);
    cfg.timeoutIntervalForResource = fmax(2.0, timeoutSec + 10.0);
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;

    if (proxy) {
        NSString *ptype = [[proxy[@"type"] description] lowercaseString] ?: @"http";
        NSString *host = proxy[@"host"] ?: @"";
        int port = [proxy[@"port"] intValue];
        NSString *user = proxy[@"user"] ?: @"";
        NSString *pass = proxy[@"pass"] ?: @"";
        if (host.length && port > 0) {
            NSMutableDictionary *pd = [NSMutableDictionary dictionary];
            if ([ptype hasPrefix:@"socks"]) {
                pd[@"SOCKSEnable"] = @1;
                pd[@"SOCKSProxy"] = host;
                pd[@"SOCKSPort"] = @(port);
                if (user.length) pd[@"SOCKSUser"] = user;
                if (pass.length) pd[@"SOCKSPassword"] = pass;
            } else {
                pd[@"HTTPEnable"] = @1;
                pd[@"HTTPProxy"] = host;
                pd[@"HTTPPort"] = @(port);
                pd[@"HTTPSEnable"] = @1;
                pd[@"HTTPSProxy"] = host;
                pd[@"HTTPSPort"] = @(port);
                if (user.length) pd[@"HTTPUser"] = user;
                if (pass.length) pd[@"HTTPPassword"] = pass;
            }
            cfg.connectionProxyDictionary = pd;
        }
    }

    TCHttpDelegate *del = [[TCHttpDelegate alloc] init];
    del.followRedirects = followRedirects;
    del.insecureTLS = insecureTLS;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:del delegateQueue:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = fmax(1.0, timeoutSec);
    for (NSString *k in headers) {
        [req setValue:headers[k] forHTTPHeaderField:k];
    }
    if (bodyData && bodyData.length > 0) {
        req.HTTPBody = bodyData;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *respData = nil;
    __block NSURLResponse *respObj = nil;
    __block NSError *respErr = nil;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        respData = d;
        respObj = r;
        respErr = e;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    BOOL stopped = NO;
    double deadline = monotonicSec() + fmax(2.0, timeoutSec + 10.0);
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
        if (tapcore_script_should_stop()) {
            stopped = YES;
            [task cancel];
            break;
        }
        if (monotonicSec() > deadline) {
            [task cancel];
            break;
        }
    }
    [session finishTasksAndInvalidate];

    if (stopped) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"", @"error": @"Stopped"};
    }
    if (respErr && !respObj) {
        return @{@"ok": @NO, @"status": @(0), @"body": @"",
                 @"error": respErr.localizedDescription ?: @"Request failed"};
    }

    int status = 0;
    NSMutableDictionary *rh = [NSMutableDictionary dictionary];
    if ([respObj isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)respObj;
        status = (int)hr.statusCode;
        for (id k in hr.allHeaderFields) {
            NSString *ks = [[k description] lowercaseString];
            NSString *vs = [hr.allHeaderFields[k] description];
            if (ks.length && vs) rh[ks] = vs;
        }
    }

    return @{
        @"ok": @(status > 0),
        @"status": @(status),
        @"body_data": respData ?: [NSData data],
        @"headers": rh
    };
}

static int l_httpRequest(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    @autoreleasepool {
        lua_getfield(L, 1, "url");
        const char *urlC = luaL_checkstring(L, -1);
        NSString *url = [NSString stringWithUTF8String:urlC];
        lua_pop(L, 1);

        NSString *method = @"GET";
        lua_getfield(L, 1, "method");
        if (lua_isstring(L, -1)) method = [[NSString stringWithUTF8String:lua_tostring(L, -1)] uppercaseString];
        lua_pop(L, 1);

        double timeoutSec = 30.0;
        lua_getfield(L, 1, "timeout");
        if (lua_isnumber(L, -1)) timeoutSec = lua_tonumber(L, -1);
        lua_pop(L, 1);

        BOOL followRedirects = YES;
        lua_getfield(L, 1, "follow_redirects");
        if (lua_isboolean(L, -1)) followRedirects = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);

        BOOL insecureTLS = NO;
        lua_getfield(L, 1, "insecure");
        if (lua_isboolean(L, -1)) insecureTLS = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);

        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        lua_getfield(L, 1, "headers");
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                    NSString *k = [NSString stringWithUTF8String:lua_tostring(L, -2)];
                    NSString *v = [NSString stringWithUTF8String:lua_tostring(L, -1)];
                    if (k.length) headers[k] = v ?: @"";
                }
                lua_pop(L, 1);
            }
        } else if (lua_isstring(L, -1)) {
            [headers addEntriesFromDictionary:parseRawHeaders([NSString stringWithUTF8String:lua_tostring(L, -1)])];
        }
        lua_pop(L, 1);

        NSData *bodyData = nil;
        lua_getfield(L, 1, "body");
        if (lua_isstring(L, -1)) {
            size_t blen = 0;
            const char *bptr = lua_tolstring(L, -1, &blen);
            if (bptr && blen > 0) bodyData = [NSData dataWithBytes:bptr length:blen];
        }
        lua_pop(L, 1);

        NSMutableDictionary *proxy = nil;
        lua_getfield(L, 1, "proxy");
        if (lua_istable(L, -1)) {
            proxy = [NSMutableDictionary dictionary];
            lua_getfield(L, -1, "type");
            if (lua_isstring(L, -1)) proxy[@"type"] = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            lua_pop(L, 1);
            lua_getfield(L, -1, "host");
            if (lua_isstring(L, -1)) proxy[@"host"] = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            lua_pop(L, 1);
            lua_getfield(L, -1, "port");
            if (lua_isnumber(L, -1)) proxy[@"port"] = @((int)lua_tointeger(L, -1));
            else if (lua_isstring(L, -1)) proxy[@"port"] = @([[NSString stringWithUTF8String:lua_tostring(L, -1)] intValue]);
            lua_pop(L, 1);
            lua_getfield(L, -1, "user");
            if (lua_isstring(L, -1)) proxy[@"user"] = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            lua_pop(L, 1);
            lua_getfield(L, -1, "pass");
            if (lua_isstring(L, -1)) proxy[@"pass"] = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            lua_pop(L, 1);
        }
        lua_pop(L, 1);

        // Route proxy requests: prefer curl for SOCKS5 or authenticated HTTP proxy if curl binary exists
        NSDictionary *res = nil;
        BOOL hasProxy = (proxy != nil && [proxy[@"host"] length] > 0 && [proxy[@"port"] intValue] > 0);
        BOOL isSocks = hasProxy && [[[proxy[@"type"] description] lowercaseString] hasPrefix:@"socks"];
        BOOL hasProxyAuth = hasProxy && ([proxy[@"user"] length] > 0 || [proxy[@"pass"] length] > 0);

        NSString *curlBin = nil;
        if (access("/var/jb/usr/bin/curl", X_OK) == 0) curlBin = @"/var/jb/usr/bin/curl";
        else if (access("/usr/bin/curl", X_OK) == 0) curlBin = @"/usr/bin/curl";

        if ((isSocks || hasProxyAuth) && curlBin) {
            res = runCurlRequest(curlBin, url, method, headers, bodyData, timeoutSec, followRedirects, insecureTLS, proxy);
        } else if (isSocks && [url.lowercaseString hasPrefix:@"http://"]) {
            res = runSocks5PlainHttp(url, method, headers, bodyData, timeoutSec, proxy);
        } else {
            res = runNSURLSessionRequest(url, method, headers, bodyData, timeoutSec, followRedirects, insecureTLS, proxy);
        }

        lua_newtable(L);
        lua_pushboolean(L, [res[@"ok"] boolValue]);
        lua_setfield(L, -2, "ok");

        lua_pushinteger(L, [res[@"status"] integerValue]);
        lua_setfield(L, -2, "status");

        NSData *bd = res[@"body_data"];
        if (bd) {
            lua_pushlstring(L, (const char *)bd.bytes, bd.length);
        } else if ([res[@"body"] isKindOfClass:[NSString class]]) {
            NSString *bs = res[@"body"];
            lua_pushstring(L, bs.UTF8String);
        } else {
            lua_pushstring(L, "");
        }
        lua_setfield(L, -2, "body");

        lua_newtable(L);
        NSDictionary *rh = res[@"headers"];
        if ([rh isKindOfClass:[NSDictionary class]]) {
            for (NSString *k in rh) {
                lua_pushstring(L, [rh[k] description].UTF8String);
                lua_setfield(L, -2, k.UTF8String);
            }
        }
        lua_setfield(L, -2, "headers");

        if ([res[@"error"] isKindOfClass:[NSString class]] && [res[@"error"] length] > 0) {
            lua_pushstring(L, [res[@"error"] UTF8String]);
            lua_setfield(L, -2, "error");
        }
    }
    return 1;
}

int luaopen_tapcore_http(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, l_httpRequest);
    lua_setfield(L, -2, "request");
    return 1;
}

void tapcore_http_register_lua(lua_State *L) {
    lua_pushcfunction(L, l_httpRequest);
    lua_setglobal(L, "httpRequest");
}
