#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>

#define TAPCORE_IPC_PORT 3001
#define TAPCORE_NOTIFY_CMD "com.tapcore.cmd"

static uint64_t g_lastSeq = 0;
static __weak id g_foundFirstResponder = nil;

@interface UIResponder (TapCoreFirstResponder)
- (void)tapcore_captureFirstResponder:(id)sender;
@end

@implementation UIResponder (TapCoreFirstResponder)
- (void)tapcore_captureFirstResponder:(id)sender {
    (void)sender;
    g_foundFirstResponder = self;
}
@end

static id findCurrentFirstResponder(void) {
    g_foundFirstResponder = nil;
    [[UIApplication sharedApplication] sendAction:@selector(tapcore_captureFirstResponder:)
                                               to:nil
                                             from:nil
                                         forEvent:nil];
    return g_foundFirstResponder;
}

static int connectTapCoreIPC(int timeoutMs) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(TAPCORE_IPC_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static BOOL readExact(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t r = recv(fd, (char *)buf + got, len - got, 0);
        if (r <= 0) return NO;
        got += (size_t)r;
    }
    return YES;
}

static BOOL readLine(int fd, char *buf, size_t maxLen) {
    size_t i = 0;
    while (i + 1 < maxLen) {
        char c = 0;
        ssize_t r = recv(fd, &c, 1, 0);
        if (r <= 0) return NO;
        if (c == '\n') break;
        if (c != '\r') buf[i++] = c;
    }
    buf[i] = '\0';
    return YES;
}

static void sendAck(uint64_t seq, const char *status) {
    int fd = connectTapCoreIPC(150);
    if (fd < 0) return;
    char msg[256];
    int n = snprintf(msg, sizeof(msg), "ACK %llu %s\n", (unsigned long long)seq, status ?: "OK");
    if (n > 0) send(fd, msg, (size_t)n, 0);
    close(fd);
}

static void handleBackspaceOrTextOnResponder(id responder, NSString *text) {
    if ([text isEqualToString:@"\b"]) {
        if ([responder respondsToSelector:@selector(deleteBackward)]) {
            ((void (*)(id, SEL))objc_msgSend)(responder, @selector(deleteBackward));
        }
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(responder, @selector(insertText:), text);
}

static NSString *performInsertText(NSString *text) {
    // 1. Best & most reliable on iOS 15-16 (works on UITextField, UITextView, Password secureTextEntry, IG, X):
    //    Deliver directly to active firstResponder implementing UIKeyInput!
    id fr = findCurrentFirstResponder();
    if (fr && ([fr conformsToProtocol:@protocol(UIKeyInput)] || [fr respondsToSelector:@selector(insertText:)])) {
        handleBackspaceOrTextOnResponder(fr, text);
        return [NSString stringWithFormat:@"FR:%@", NSStringFromClass([fr class])];
    }

    // 2. Fallback: UIKeyboardImpl -> delegate / inputDelegate -> addInputString / insertText
    Class kbCls = NSClassFromString(@"UIKeyboardImpl");
    if (!kbCls) return nil;

    id kb = nil;
    if ([kbCls respondsToSelector:@selector(activeInstance)]) {
        kb = ((id (*)(id, SEL))objc_msgSend)(kbCls, @selector(activeInstance));
    }
    if (!kb && [kbCls respondsToSelector:@selector(sharedInstance)]) {
        kb = ((id (*)(id, SEL))objc_msgSend)(kbCls, @selector(sharedInstance));
    }
    if (!kb) return nil;

    id delegate = nil;
    if ([kb respondsToSelector:@selector(delegate)]) {
        delegate = ((id (*)(id, SEL))objc_msgSend)(kb, @selector(delegate));
    }
    if (!delegate && [kb respondsToSelector:@selector(inputDelegate)]) {
        delegate = ((id (*)(id, SEL))objc_msgSend)(kb, @selector(inputDelegate));
    }
    if (delegate && ([delegate conformsToProtocol:@protocol(UIKeyInput)] || [delegate respondsToSelector:@selector(insertText:)])) {
        handleBackspaceOrTextOnResponder(delegate, text);
        return [NSString stringWithFormat:@"KBDel:%@", NSStringFromClass([delegate class])];
    }

    if (delegate && [kb respondsToSelector:@selector(addInputString:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(kb, @selector(addInputString:), text);
        return @"KB:addInputString";
    }
    if (delegate && [kb respondsToSelector:@selector(insertText:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(kb, @selector(insertText:), text);
        return @"KB:insertText";
    }
    return nil;
}

static NSArray<UIWindow *> *collectVisibleWindows(UIApplication *app) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (!w.hidden && w.alpha > 0.01) [wins addObject:w];
            }
        }
    }
    if (wins.count == 0) {
        for (UIWindow *w in app.windows) {
            if (!w.hidden && w.alpha > 0.01) [wins addObject:w];
        }
    }
    return [wins sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.isKeyWindow != b.isKeyWindow) return a.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        if (a.windowLevel != b.windowLevel) return (a.windowLevel > b.windowLevel) ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static id findVisibleViewOfClass(UIView *view, Class cls) {
    if (!view || view.hidden || view.alpha < 0.01) return nil;
    if ([view isKindOfClass:cls]) return view;
    for (UIView *sub in [view.subviews reverseObjectEnumerator]) {
        id found = findVisibleViewOfClass(sub, cls);
        if (found) return found;
    }
    return nil;
}

static BOOL parseDateSpec(NSString *spec, NSInteger *outYear, NSInteger *outMonth, NSInteger *outDay) {
    NSString *s = [spec stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    int y = 0, m = 0, d = 0;
    if (s.length >= 8 && sscanf(s.UTF8String, "%d-%d-%d", &y, &m, &d) == 3 &&
        y >= 1900 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        *outYear = y;
        *outMonth = m;
        *outDay = d;
        return YES;
    }
    if (s.length == 0 || [[s lowercaseString] isEqualToString:@"random"]) {
        *outYear = 1992 + (NSInteger)arc4random_uniform(13);   // 1992..2004
        *outMonth = 1 + (NSInteger)arc4random_uniform(12);     // 1..12
        *outDay = 1 + (NSInteger)arc4random_uniform(28);       // 1..28
        return YES;
    }
    return NO;
}

static NSString *performSetDate(NSString *spec) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    NSInteger year = 0, month = 0, day = 0;
    if (!parseDateSpec(spec ?: @"", &year, &month, &day)) return nil;

    NSArray<UIWindow *> *windows = collectVisibleWindows(app);

    // 1. Standard UIDatePicker (Instagram / Meta / iOS sheets)
    for (UIWindow *w in windows) {
        UIDatePicker *dp = (UIDatePicker *)findVisibleViewOfClass(w, [UIDatePicker class]);
        if (!dp) continue;

        NSCalendar *cal = dp.calendar ?: [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        NSTimeZone *tz = dp.timeZone ?: [NSTimeZone localTimeZone];
        cal.timeZone = tz;

        NSDateComponents *comps = [[NSDateComponents alloc] init];
        comps.calendar = cal;
        comps.timeZone = tz;
        comps.year = year;
        comps.month = month;
        comps.day = day;
        comps.hour = 12;
        NSDate *target = [cal dateFromComponents:comps];
        if (!target) return nil;

        if (dp.minimumDate && [target compare:dp.minimumDate] == NSOrderedAscending) target = dp.minimumDate;
        if (dp.maximumDate && [target compare:dp.maximumDate] == NSOrderedDescending) target = dp.maximumDate;

        [dp setDate:target animated:NO];
        [dp sendActionsForControlEvents:UIControlEventValueChanged];

        NSDateComponents *finalComps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:dp.date ?: target];
        return [NSString stringWithFormat:@"UIDatePicker:%04ld-%02ld-%02ld",
                (long)finalComps.year, (long)finalComps.month, (long)finalComps.day];
    }

    // 2. Fallback: custom 3-column UIPickerView (Month / Day / Year)
    for (UIWindow *w in windows) {
        UIPickerView *pv = (UIPickerView *)findVisibleViewOfClass(w, [UIPickerView class]);
        if (!pv || pv.numberOfComponents != 3) continue;

        id<UIPickerViewDelegate> del = pv.delegate;
        id<UIPickerViewDataSource> ds = pv.dataSource;
        if (!ds || ![ds respondsToSelector:@selector(pickerView:numberOfRowsInComponent:)]) continue;

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSString *monthFull = (month >= 1 && month <= 12) ? df.monthSymbols[month - 1] : @"";
        NSString *monthShort = (month >= 1 && month <= 12) ? df.shortMonthSymbols[month - 1] : @"";
        NSString *yearStr = [NSString stringWithFormat:@"%ld", (long)year];
        NSString *dayStr = [NSString stringWithFormat:@"%ld", (long)day];
        NSString *dayPad = [NSString stringWithFormat:@"%02ld", (long)day];

        NSInteger matchedCols = 0;
        for (NSInteger comp = 0; comp < 3; comp++) {
            NSInteger rows = [ds pickerView:pv numberOfRowsInComponent:comp];
            if (rows <= 0) continue;
            BOOL looksYear = NO, looksDay = NO, looksMonth = NO;
            NSInteger probeMax = MIN(rows, (NSInteger)15);
            for (NSInteger r = 0; r < probeMax; r++) {
                NSString *t = nil;
                if ([del respondsToSelector:@selector(pickerView:titleForRow:forComponent:)]) {
                    t = [del pickerView:pv titleForRow:r forComponent:comp];
                } else if ([del respondsToSelector:@selector(pickerView:attributedTitleForRow:forComponent:)]) {
                    t = [del pickerView:pv attributedTitleForRow:r forComponent:comp].string;
                }
                if (!t) continue;
                NSInteger num = t.integerValue;
                if (num >= 1900 && num <= 2100) looksYear = YES;
                else if (num >= 1 && num <= 31 && t.length <= 2) looksDay = YES;
                else if (t.length >= 3) looksMonth = YES;
            }
            NSInteger targetRow = -1;
            for (NSInteger r = 0; r < rows; r++) {
                NSString *t = nil;
                if ([del respondsToSelector:@selector(pickerView:titleForRow:forComponent:)]) {
                    t = [del pickerView:pv titleForRow:r forComponent:comp];
                } else if ([del respondsToSelector:@selector(pickerView:attributedTitleForRow:forComponent:)]) {
                    t = [del pickerView:pv attributedTitleForRow:r forComponent:comp].string;
                }
                if (!t) continue;
                NSString *tr = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (looksYear && [tr isEqualToString:yearStr]) { targetRow = r; break; }
                if (looksDay && ([tr isEqualToString:dayStr] || [tr isEqualToString:dayPad])) { targetRow = r; break; }
                if (looksMonth && ([[tr lowercaseString] isEqualToString:[monthFull lowercaseString]] ||
                                   [[tr lowercaseString] isEqualToString:[monthShort lowercaseString]])) {
                    targetRow = r; break;
                }
            }
            if (targetRow >= 0) {
                [pv selectRow:targetRow inComponent:comp animated:NO];
                if ([del respondsToSelector:@selector(pickerView:didSelectRow:inComponent:)]) {
                    [del pickerView:pv didSelectRow:targetRow inComponent:comp];
                }
                matchedCols++;
            }
        }
        if (matchedCols >= 2) {
            return [NSString stringWithFormat:@"UIPickerView:%04ld-%02ld-%02ld",
                    (long)year, (long)month, (long)day];
        }
    }
    return nil;
}

static void handleTapCoreCommand(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        __block BOOL isActive = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            isActive = (app && app.applicationState == UIApplicationStateActive);
        });
        if (!isActive) return;

        int fd = connectTapCoreIPC(150);
        if (fd < 0) return;

        const char *req = "GET\n";
        if (send(fd, req, 4, 0) != 4) { close(fd); return; }

        char header[128];
        if (!readLine(fd, header, sizeof(header))) { close(fd); return; }

        unsigned long long seq = 0;
        char op[32] = {0};
        unsigned long len = 0;
        if (sscanf(header, "%llu %31s %lu", &seq, op, &len) != 3 || seq == 0 || len > 1048576) {
            close(fd);
            return;
        }
        if (seq == g_lastSeq) {
            close(fd);
            return;
        }

        char *payload = (char *)malloc(len + 1);
        if (!payload) { close(fd); return; }
        if (len > 0 && !readExact(fd, payload, len)) {
            free(payload);
            close(fd);
            return;
        }
        payload[len] = '\0';
        close(fd);

        NSString *text = [[NSString alloc] initWithBytes:payload length:len encoding:NSUTF8StringEncoding];
        free(payload);
        if (!text) text = @"";

        NSString *opStr = [NSString stringWithUTF8String:op];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            if (!app || app.applicationState != UIApplicationStateActive) return;
            if (seq == g_lastSeq) return;

            if ([opStr isEqualToString:@"copy"]) {
                g_lastSeq = seq;
                [UIPasteboard generalPasteboard].string = text;
                NSString *info = [NSString stringWithFormat:@"%@/pasteboard",
                                  [NSBundle mainBundle].bundleIdentifier ?: @"?"];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    sendAck(seq, info.UTF8String);
                });
            } else if ([opStr isEqualToString:@"input"]) {
                NSString *how = performInsertText(text);
                if (how) {
                    g_lastSeq = seq;
                    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
                    NSString *info = [NSString stringWithFormat:@"%@/%@", bid, how];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                        sendAck(seq, info.UTF8String);
                    });
                }
            } else if ([opStr isEqualToString:@"setdate"]) {
                NSString *how = performSetDate(text);
                if (how) {
                    g_lastSeq = seq;
                    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
                    NSString *info = [NSString stringWithFormat:@"%@/%@", bid, how];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                        sendAck(seq, info.UTF8String);
                    });
                }
            }
        });
    });
}

static void darwinCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    handleTapCoreCommand();
}

__attribute__((constructor))
static void tapcoreInputInit(void) {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        if (!bid || [bid isEqualToString:@"com.apple.springboard"] ||
            [bid isEqualToString:@"com.apple.backboardd"]) {
            return;
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            darwinCallback,
            CFSTR(TAPCORE_NOTIFY_CMD),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
}
