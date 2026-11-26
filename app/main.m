#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AudioToolbox/AudioToolbox.h>

#define TAPCORE_PORT_FILE "/tmp/tapcore.port"

static UIColor *hexColor(uint32_t rgb, CGFloat a) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:a];
}

static NSString *localDaemonBaseURL(void) {
    int port = 8080;
    NSString *s = [NSString stringWithContentsOfFile:@TAPCORE_PORT_FILE encoding:NSUTF8StringEncoding error:nil];
    if (s.length > 0) {
        int p = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].intValue;
        if (p > 0) port = p;
    }
    return [NSString stringWithFormat:@"http://127.0.0.1:%d", port];
}

static void apiRequest(NSString *method, NSString *path, NSData *body, void (^done)(NSDictionary *json, NSString *raw, NSError *err)) {
    NSURL *url = [NSURL URLWithString:[localDaemonBaseURL() stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 15.0;
    if (body) {
        req.HTTPBody = body;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        (void)resp;
        NSDictionary *j = nil;
        NSString *raw = nil;
        if (data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) j = obj;
            raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(j, raw, error);
        });
    }] resume];
}

// ---------------- 1. Embedded Studio WebView Controller ----------------
@interface TCWebStudioVC : UIViewController
@property (nonatomic, copy) NSString *initialView;
@end

@implementation TCWebStudioVC {
    WKWebView *_web;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = hexColor(0x090D16, 1.0);
    self.title = @"Image & Vision Studio";

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    _web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.opaque = NO;
    _web.backgroundColor = hexColor(0x090D16, 1.0);
    [self.view addSubview:_web];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(reloadPage)];
    [self reloadPage];
}
- (void)reloadPage {
    NSURL *url = [NSURL URLWithString:[localDaemonBaseURL() stringByAppendingString:@"/"]];
    [_web loadRequest:[NSURLRequest requestWithURL:url]];
}
@end

// ---------------- 2. Script Code Editor Controller ----------------
@interface TapCoreScriptEditorVC : UIViewController
@property (nonatomic, copy) NSString *scriptPath;
@end

@implementation TapCoreScriptEditorVC {
    UITextView *_editor;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.scriptPath;
    self.view.backgroundColor = hexColor(0x080C15, 1.0);

    _editor = [[UITextView alloc] initWithFrame:self.view.bounds];
    _editor.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _editor.backgroundColor = hexColor(0x080C15, 1.0);
    _editor.textColor = hexColor(0xDBEAFE, 1.0);
    _editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.smartQuotesType = UITextSmartQuotesTypeNo;
    _editor.smartDashesType = UITextSmartDashesTypeNo;
    _editor.contentInset = UIEdgeInsetsMake(10, 10, 120, 10);
    [self.view addSubview:_editor];

    UIBarButtonItem *saveBtn = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStylePlain target:self action:@selector(saveScript)];
    UIBarButtonItem *runBtn  = [[UIBarButtonItem alloc] initWithTitle:@"Run" style:UIBarButtonItemStyleDone target:self action:@selector(saveAndRun)];
    self.navigationItem.rightBarButtonItems = @[runBtn, saveBtn];

    NSString *enc = [self.scriptPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    apiRequest(@"GET", [@"/api/script?path=" stringByAppendingString:enc], nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)j; (void)err;
        self->_editor.text = raw ?: @"";
    });
}
- (void)saveScriptWithCompletion:(void (^)(BOOL ok))cb {
    NSString *enc = [self.scriptPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSData *body = [_editor.text dataUsingEncoding:NSUTF8StringEncoding];
    apiRequest(@"POST", [@"/api/script?path=" stringByAppendingString:enc], body, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw;
        BOOL ok = (!err && [j[@"success"] boolValue]);
        if (cb) cb(ok);
    });
}
- (void)saveScript {
    [self saveScriptWithCompletion:^(BOOL ok) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:ok ? @"Saved" : @"Error"
                                                                 message:ok ? self.scriptPath : @"Failed to save script"
                                                          preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }];
}
- (void)saveAndRun {
    [self saveScriptWithCompletion:^(BOOL ok) {
        if (!ok) return;
        NSString *enc = [self.scriptPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        apiRequest(@"POST", [@"/api/run?path=" stringByAppendingString:enc], nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)j; (void)raw; (void)err;
            [self.navigationController popToRootViewControllerAnimated:YES];
        });
    }];
}
@end

// ---------------- 3. Scripts Manager Controller ----------------
@interface TapCoreScriptsVC : UITableViewController
@end

@implementation TapCoreScriptsVC {
    NSArray<NSDictionary *> *_scripts;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lua Scripts";
    self.view.backgroundColor = hexColor(0x090D16, 1.0);
    self.tableView.backgroundColor = hexColor(0x090D16, 1.0);
    self.tableView.separatorColor = hexColor(0x1E293B, 1.0);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(newScriptPrompt)];
    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(reloadScripts) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadScripts];
}
- (void)reloadScripts {
    apiRequest(@"GET", @"/api/scripts", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw; (void)err;
        self->_scripts = [j[@"scripts"] isKindOfClass:[NSArray class]] ? j[@"scripts"] : @[];
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
    });
}
- (void)newScriptPrompt {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"New Lua Script"
                                                             message:@"Enter filename (e.g. task.lua)"
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"my_script.lua"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        NSString *name = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length == 0) return;
        if (![name hasSuffix:@".lua"]) name = [name stringByAppendingString:@".lua"];
        NSString *enc = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        NSData *body = [[NSString stringWithFormat:@"-- %@\nprint('Started %@')\n", name, name] dataUsingEncoding:NSUTF8StringEncoding];
        apiRequest(@"POST", [@"/api/script?path=" stringByAppendingString:enc], body, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)j; (void)raw; (void)err;
            TapCoreScriptEditorVC *ed = [[TapCoreScriptEditorVC alloc] init];
            ed.scriptPath = name;
            [self.navigationController pushViewController:ed animated:YES];
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { (void)tv; (void)s; return _scripts.count; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { (void)tv; (void)ip; return 68; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"sc"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"sc"];
        cell.backgroundColor = hexColor(0x111827, 1.0);
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightSemibold];
        cell.detailTextLabel.textColor = hexColor(0x8899B5, 1.0);
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *item = _scripts[ip.row];
    BOOL running = [item[@"running"] boolValue];
    cell.textLabel.text = item[@"name"];
    double kb = [item[@"size"] doubleValue] / 1024.0;
    cell.detailTextLabel.text = running ? [NSString stringWithFormat:@"RUNNING · %.1f KB", kb]
                                        : [NSString stringWithFormat:@"%.1f KB · Tap to edit", kb];
    cell.detailTextLabel.textColor = running ? hexColor(0x34D399, 1.0) : hexColor(0x8899B5, 1.0);

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(0, 0, 74, 34);
    btn.layer.cornerRadius = 9;
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    btn.tag = ip.row;
    if (running) {
        [btn setTitle:@"STOP" forState:UIControlStateNormal];
        [btn setTitleColor:hexColor(0xFDA4AF, 1.0) forState:UIControlStateNormal];
        btn.backgroundColor = hexColor(0xF43F5E, 0.22);
    } else {
        [btn setTitle:@"PLAY" forState:UIControlStateNormal];
        [btn setTitleColor:hexColor(0x6EE7B7, 1.0) forState:UIControlStateNormal];
        btn.backgroundColor = hexColor(0x10B981, 0.20);
    }
    [btn addTarget:self action:@selector(toggleRun:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = btn;
    return cell;
}
- (void)toggleRun:(UIButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_scripts.count) return;
    NSDictionary *item = _scripts[sender.tag];
    if ([item[@"running"] boolValue]) {
        apiRequest(@"POST", @"/api/stop", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)j; (void)raw; (void)err;
            [self reloadScripts];
        });
    } else {
        NSString *enc = [item[@"path"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        apiRequest(@"POST", [@"/api/run?path=" stringByAppendingString:enc], nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)j; (void)raw; (void)err;
            [self reloadScripts];
        });
    }
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    NSDictionary *item = _scripts[ip.row];
    TapCoreScriptEditorVC *ed = [[TapCoreScriptEditorVC alloc] init];
    ed.scriptPath = item[@"path"];
    [self.navigationController pushViewController:ed animated:YES];
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    if (style == UITableViewCellEditingStyleDelete) {
        NSString *enc = [_scripts[ip.row][@"path"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        apiRequest(@"DELETE", [@"/api/script?path=" stringByAppendingString:enc], nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)j; (void)raw; (void)err;
            [self reloadScripts];
        });
    }
}
@end

// ---------------- 4. Control Deck Main Dashboard ----------------
@interface TapCoreDashboardVC : UIViewController
@end

@implementation TapCoreDashboardVC {
    UIScrollView *_scroll;
    UIView   *_dotConn;
    UILabel  *_lblWebURL;
    UILabel  *_lblRunState;
    UIButton *_btnStop;
    UIButton *_btnRec;
    UILabel  *_lblRecSub;
    UILabel  *_lblCapSub;
    UITextView *_logView;
    NSTimer  *_timer;
    uint64_t _lastLogId;
    NSDictionary *_lastStatus;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = hexColor(0x090D16, 1.0);
    self.title = @"TapCore";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Auto-Start"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(openAutoStartPicker)];
    [self buildUI];
    [self pollAll];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(pollAll) userInfo:nil repeats:YES];
}

- (UIButton *)makeTileWithTitle:(NSString *)title sub:(NSString *)sub accent:(uint32_t)rgb action:(SEL)sel outSub:(UILabel * __strong *)outSub {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = hexColor(0x121B2E, 1.0);
    b.layer.cornerRadius = 18;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = hexColor(rgb, 0.40).CGColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];

    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(16, 16, 10, 10)];
    badge.layer.cornerRadius = 5;
    badge.backgroundColor = hexColor(rgb, 1.0);
    badge.userInteractionEnabled = NO;
    [b addSubview:badge];

    UILabel *lt = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, 140, 22)];
    lt.text = title;
    lt.textColor = [UIColor whiteColor];
    lt.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    lt.userInteractionEnabled = NO;
    [b addSubview:lt];

    UILabel *ls = [[UILabel alloc] initWithFrame:CGRectMake(16, 62, 140, 34)];
    ls.text = sub;
    ls.numberOfLines = 2;
    ls.textColor = hexColor(0x8899B5, 1.0);
    ls.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    ls.userInteractionEnabled = NO;
    [b addSubview:ls];
    if (outSub) *outSub = ls;
    return b;
}

- (UILabel *)makeSectionHeader:(NSString *)text frame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    l.textColor = hexColor(0x64748B, 1.0);
    return l;
}

- (UIButton *)makeSystemPill:(NSString *)title accent:(uint32_t)rgb frame:(CGRect)frame action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    b.backgroundColor = hexColor(rgb, 0.14);
    b.layer.cornerRadius = 12;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = hexColor(rgb, 0.45).CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:hexColor(rgb, 1.0) forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildUI {
    CGFloat W = self.view.bounds.size.width;
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scroll];

    CGFloat pad = 16;
    CGFloat cw = W - pad * 2;
    CGFloat y = 12;

    // SECTION 1: SERVER & RUNNER STATUS
    [_scroll addSubview:[self makeSectionHeader:@"SERVER & RUNNER" frame:CGRectMake(pad + 4, y, cw, 18)]];
    y += 22;

    UIView *hero = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 134)];
    hero.backgroundColor = hexColor(0x121B2E, 1.0);
    hero.layer.cornerRadius = 20;
    hero.layer.borderWidth = 1;
    hero.layer.borderColor = hexColor(0x263554, 1.0).CGColor;
    [_scroll addSubview:hero];

    _dotConn = [[UIView alloc] initWithFrame:CGRectMake(16, 18, 10, 10)];
    _dotConn.layer.cornerRadius = 5;
    _dotConn.backgroundColor = hexColor(0x64748B, 1.0);
    [hero addSubview:_dotConn];

    UILabel *lblTag = [[UILabel alloc] initWithFrame:CGRectMake(34, 13, cw - 50, 20)];
    lblTag.text = @"WEB STUDIO URL (TAP TO COPY)";
    lblTag.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    lblTag.textColor = hexColor(0x8899B5, 1.0);
    [hero addSubview:lblTag];

    _lblWebURL = [[UILabel alloc] initWithFrame:CGRectMake(16, 36, cw - 32, 28)];
    _lblWebURL.text = @"Connecting to TapCore daemon...";
    _lblWebURL.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold];
    _lblWebURL.textColor = hexColor(0x22D3EE, 1.0);
    _lblWebURL.userInteractionEnabled = YES;
    [_lblWebURL addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyWebURL)]];
    [hero addSubview:_lblWebURL];

    _lblRunState = [[UILabel alloc] initWithFrame:CGRectMake(16, 70, cw - 120, 46)];
    _lblRunState.text = @"Status: IDLE";
    _lblRunState.numberOfLines = 2;
    _lblRunState.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    _lblRunState.textColor = hexColor(0xCBD5E1, 1.0);
    [hero addSubview:_lblRunState];

    _btnStop = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnStop.frame = CGRectMake(cw - 96, 76, 80, 38);
    _btnStop.layer.cornerRadius = 11;
    _btnStop.backgroundColor = hexColor(0xF43F5E, 1.0);
    [_btnStop setTitle:@"STOP" forState:UIControlStateNormal];
    [_btnStop setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _btnStop.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _btnStop.hidden = YES;
    [_btnStop addTarget:self action:@selector(stopRunning) forControlEvents:UIControlEventTouchUpInside];
    [hero addSubview:_btnStop];

    y += 148;

    // SECTION 2: AUTOMATION
    CGFloat gap = 12;
    CGFloat tw = (cw - gap) / 2.0;
    CGFloat th = 104;

    [_scroll addSubview:[self makeSectionHeader:@"AUTOMATION" frame:CGRectMake(pad + 4, y, cw, 18)]];
    y += 22;

    UIButton *bScripts = [self makeTileWithTitle:@"Scripts" sub:@"Play, stop & edit any .lua" accent:0x06B6D4 action:@selector(openScripts) outSub:nil];
    bScripts.frame = CGRectMake(pad, y, tw, th);
    [_scroll addSubview:bScripts];

    _btnRec = [self makeTileWithTitle:@"Record Touch" sub:@"Capture real taps & swipes" accent:0xF43F5E action:@selector(toggleRecord) outSub:&_lblRecSub];
    _btnRec.frame = CGRectMake(pad + tw + gap, y, tw, th);
    [_scroll addSubview:_btnRec];

    y += th + 16;

    // SECTION 3: IMAGE & VISION
    [_scroll addSubview:[self makeSectionHeader:@"IMAGE & VISION" frame:CGRectMake(pad + 4, y, cw, 18)]];
    y += 22;

    UIButton *bStudio = [self makeTileWithTitle:@"Image Studio" sub:@"Crop, color pick & OCR" accent:0x6366F1 action:@selector(openStudio) outSub:nil];
    bStudio.frame = CGRectMake(pad, y, tw, th);
    [_scroll addSubview:bStudio];

    UIButton *bCap = [self makeTileWithTitle:@"Capture 3s" sub:@"Delay 3s & save PNG" accent:0x10B981 action:@selector(captureDelayed) outSub:&_lblCapSub];
    bCap.frame = CGRectMake(pad + tw + gap, y, tw, th);
    [_scroll addSubview:bCap];

    y += th + 16;

    // SECTION 4: SYSTEM TOOLS (UICache / Respring / Restart Daemon)
    [_scroll addSubview:[self makeSectionHeader:@"SYSTEM TOOLS" frame:CGRectMake(pad + 4, y, cw, 18)]];
    y += 22;

    CGFloat sgap = 10;
    CGFloat sw3 = (cw - sgap * 2) / 3.0;
    [_scroll addSubview:[self makeSystemPill:@"UICache"  accent:0x38BDF8 frame:CGRectMake(pad, y, sw3, 44) action:@selector(runUICache)]];
    [_scroll addSubview:[self makeSystemPill:@"Respring" accent:0xF59E0B frame:CGRectMake(pad + sw3 + sgap, y, sw3, 44) action:@selector(confirmRespring)]];
    [_scroll addSubview:[self makeSystemPill:@"Restart"  accent:0xA78BFA frame:CGRectMake(pad + (sw3 + sgap) * 2, y, sw3, 44) action:@selector(confirmRestartDaemon)]];

    y += 58;

    // SECTION 5: LIVE CONSOLE
    [_scroll addSubview:[self makeSectionHeader:@"LIVE CONSOLE" frame:CGRectMake(pad + 4, y, cw - 70, 18)]];
    UIButton *clr = [UIButton buttonWithType:UIButtonTypeSystem];
    clr.frame = CGRectMake(W - pad - 56, y - 4, 56, 26);
    [clr setTitle:@"Clear" forState:UIControlStateNormal];
    [clr setTitleColor:hexColor(0x94A3B8, 1.0) forState:UIControlStateNormal];
    clr.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [clr addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:clr];
    y += 22;

    UIView *logCard = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 240)];
    logCard.backgroundColor = hexColor(0x0B101D, 1.0);
    logCard.layer.cornerRadius = 18;
    logCard.layer.borderWidth = 1;
    logCard.layer.borderColor = hexColor(0x1E293B, 1.0).CGColor;
    [_scroll addSubview:logCard];

    _logView = [[UITextView alloc] initWithFrame:CGRectMake(10, 10, cw - 20, 220)];
    _logView.backgroundColor = [UIColor clearColor];
    _logView.textColor = hexColor(0x93C5FD, 1.0);
    _logView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    _logView.editable = NO;
    [logCard addSubview:_logView];

    y += 260;
    _scroll.contentSize = CGSizeMake(W, y);
}

- (void)runUICache {
    AudioServicesPlaySystemSound(1519);
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"op": @"uicache"} options:0 error:nil];
    apiRequest(@"POST", @"/api/system", body, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw;
        BOOL ok = (!err && [j[@"success"] boolValue]);
        UIAlertController *a = [UIAlertController alertControllerWithTitle:ok ? @"UICache Running" : @"Error"
                                                                 message:ok ? @"Refreshing Home Screen icons (uicache -a). Watch Live Console for completion." : @"Could not trigger uicache."
                                                          preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    });
}

- (void)confirmRespring {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Respring iPhone?"
                                                             message:@"Restart SpringBoard now (sbreload)."
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        (void)act;
        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"op": @"respring"} options:0 error:nil];
        apiRequest(@"POST", @"/api/system", body, nil);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmRestartDaemon {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart TapCore daemon?"
                                                             message:@"Reload daemon & re-bind Web Server port."
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        (void)act;
        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"op": @"restart_daemon"} options:0 error:nil];
        apiRequest(@"POST", @"/api/system", body, nil);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)copyWebURL {
    if (_lastStatus[@"ip"] && _lastStatus[@"web_port"]) {
        NSString *u = [NSString stringWithFormat:@"http://%@:%@", _lastStatus[@"ip"], _lastStatus[@"web_port"]];
        [UIPasteboard generalPasteboard].string = u;
        AudioServicesPlaySystemSound(1519);
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Copied URL"
                                                                 message:u
                                                          preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)stopRunning {
    apiRequest(@"POST", @"/api/stop", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)j; (void)raw; (void)err;
        AudioServicesPlaySystemSound(1519);
        [self pollAll];
    });
}

- (void)openScripts {
    [self.navigationController pushViewController:[[TapCoreScriptsVC alloc] init] animated:YES];
}

- (void)openStudio {
    [self.navigationController pushViewController:[[TCWebStudioVC alloc] init] animated:YES];
}

- (void)captureDelayed {
    _lblCapSub.text = @"Capturing in 3s...";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HHmmss";
    NSString *name = [NSString stringWithFormat:@"cap_%@.png", [df stringFromDate:[NSDate date]]];
    NSString *p = [NSString stringWithFormat:@"/api/capture?delay=3&save=%@&json=1", name];
    apiRequest(@"GET", p, nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw;
        AudioServicesPlaySystemSound(1519);
        if (!err && [j[@"success"] boolValue]) {
            self->_lblCapSub.text = [@"Saved " stringByAppendingString:name];
        } else {
            self->_lblCapSub.text = @"Capture failed";
        }
    });
}

- (void)toggleRecord {
    BOOL rec = [_lastStatus[@"recording"] boolValue];
    if (!rec) {
        apiRequest(@"POST", @"/api/record/start", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)j; (void)raw; (void)err;
            AudioServicesPlaySystemSound(1519);
            [self pollAll];
        });
    } else {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HHmmss";
        NSString *name = [NSString stringWithFormat:@"rec_%@.lua", [df stringFromDate:[NSDate date]]];
        apiRequest(@"POST", [@"/api/record/stop?save=" stringByAppendingString:name], nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
            (void)raw; (void)err;
            AudioServicesPlaySystemSound(1520);
            NSInteger evs = [j[@"events"] integerValue];
            self->_lblRecSub.text = [NSString stringWithFormat:@"Saved %@ (%ld)", name, (long)evs];
            [self pollAll];
        });
    }
}

- (void)openAutoStartPicker {
    apiRequest(@"GET", @"/api/scripts", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw; (void)err;
        NSArray *scripts = [j[@"scripts"] isKindOfClass:[NSArray class]] ? j[@"scripts"] : @[];
        NSString *cur = self->_lastStatus[@"auto_start_script"] ?: @"";
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Auto-Start Script on Boot"
                                                                       message:cur.length ? [@"Current: " stringByAppendingString:cur] : @"Current: None (Manual)"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"None (Manual only)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            (void)a;
            NSData *b = [NSJSONSerialization dataWithJSONObject:@{@"auto_start_script": @""} options:0 error:nil];
            apiRequest(@"POST", @"/api/config", b, ^(NSDictionary *r, NSString *rw, NSError *e){ (void)r;(void)rw;(void)e; [self pollAll]; });
        }]];
        for (NSDictionary *s in scripts) {
            NSString *p = s[@"path"];
            [sheet addAction:[UIAlertAction actionWithTitle:p style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                (void)a;
                NSData *b = [NSJSONSerialization dataWithJSONObject:@{@"auto_start_script": p} options:0 error:nil];
                apiRequest(@"POST", @"/api/config", b, ^(NSDictionary *r, NSString *rw, NSError *e){ (void)r;(void)rw;(void)e; [self pollAll]; });
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    });
}

- (void)clearLogs {
    apiRequest(@"POST", @"/api/logs/clear", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)j; (void)raw; (void)err;
        self->_logView.text = @"";
    });
}

- (void)pollAll {
    apiRequest(@"GET", @"/api/status", nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw;
        if (err || !j) {
            self->_dotConn.backgroundColor = hexColor(0xF43F5E, 1.0);
            self->_lblWebURL.text = @"TapCore daemon offline";
            return;
        }
        self->_lastStatus = j;
        self->_dotConn.backgroundColor = hexColor(0x10B981, 1.0);
        self->_lblWebURL.text = [NSString stringWithFormat:@"http://%@:%@", j[@"ip"], j[@"web_port"]];
        BOOL running = [j[@"running"] boolValue];
        if (running) {
            self->_lblRunState.text = [NSString stringWithFormat:@"RUNNING: %@\nUptime: %@s", j[@"script"], j[@"uptime_s"]];
            self->_lblRunState.textColor = hexColor(0x6EE7B7, 1.0);
            self->_btnStop.hidden = NO;
        } else {
            NSString *as = j[@"auto_start_script"];
            self->_lblRunState.text = [NSString stringWithFormat:@"IDLE · %@x%@\nAuto-start: %@",
                                       j[@"screen_w"], j[@"screen_h"], [as length] ? as : @"OFF"];
            self->_lblRunState.textColor = hexColor(0x94A3B8, 1.0);
            self->_btnStop.hidden = YES;
        }
        BOOL rec = [j[@"recording"] boolValue];
        if (rec) {
            self->_lblRecSub.text = [NSString stringWithFormat:@"REC LIVE · %@ events\nTap to stop & save", j[@"record_events"]];
            self->_btnRec.layer.borderColor = hexColor(0xF43F5E, 1.0).CGColor;
        } else if ([self->_lblRecSub.text hasPrefix:@"REC LIVE"]) {
            self->_lblRecSub.text = @"Capture real taps & swipes";
            self->_btnRec.layer.borderColor = hexColor(0xF43F5E, 0.40).CGColor;
        }
    });

    NSString *lp = [NSString stringWithFormat:@"/api/logs?since=%llu", (unsigned long long)_lastLogId];
    apiRequest(@"GET", lp, nil, ^(NSDictionary *j, NSString *raw, NSError *err) {
        (void)raw; (void)err;
        NSArray *logs = [j[@"logs"] isKindOfClass:[NSArray class]] ? j[@"logs"] : nil;
        if (logs.count == 0) return;
        NSMutableString *add = [NSMutableString string];
        for (NSDictionary *l in logs) {
            uint64_t lid = [l[@"id"] unsignedLongLongValue];
            if (lid > self->_lastLogId) self->_lastLogId = lid;
            [add appendFormat:@"[%@ %@] %@\n", l[@"ts"], l[@"tag"], l[@"msg"]];
        }
        self->_logView.text = [self->_logView.text stringByAppendingString:add];
        if (self->_logView.text.length > 0) {
            [self->_logView scrollRangeToVisible:NSMakeRange(self->_logView.text.length - 1, 1)];
        }
    });
}
@end

// ---------------- AppDelegate ----------------
@interface TapCoreAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation TapCoreAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithOpaqueBackground];
    ap.backgroundColor = hexColor(0x0D1424, 1.0);
    ap.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    [UINavigationBar appearance].standardAppearance = ap;
    [UINavigationBar appearance].scrollEdgeAppearance = ap;
    [UINavigationBar appearance].tintColor = hexColor(0x22D3EE, 1.0);

    TapCoreDashboardVC *root = [[TapCoreDashboardVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TapCoreAppDelegate class]));
    }
}
