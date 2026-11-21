#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kEnabled = @"ttpanel_enabled";
static NSString *const kUsers = @"ttpanel_users";
static NSString *const kMessage = @"ttpanel_message";
static NSString *const kSent = @"ttpanel_sent";

static BOOL gSenderReady = NO;
static BOOL gRunning = NO;

static NSUserDefaults *D(void) {
    return NSUserDefaults.standardUserDefaults;
}

static NSString *TTToday(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:NSDate.date];
}

static NSArray<NSString *> *TTUsers(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *raw = [D() stringForKey:kUsers] ?: @"";
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *u = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
        if ([u hasPrefix:@"@"]) u = [u substringFromIndex:1];
        if (u.length && ![seen containsObject:u]) {
            [seen addObject:u];
            [out addObject:u];
        }
    }
    return out;
}

static BOOL TTSentToday(NSString *u) {
    NSDictionary *d = [D() dictionaryForKey:kSent];
    return [d[u] isEqualToString:TTToday()];
}

static void TTMarkSent(NSString *u) {
    NSMutableDictionary *d = [([D() dictionaryForKey:kSent] ?: @{}) mutableCopy];
    d[u] = TTToday();
    [D() setObject:d forKey:kSent];
}

static void TTSendMessage(NSString *username, NSString *text, void (^done)(BOOL ok)) {
    done(NO);
}

static void TTRunDaily(void (^log)(NSString *)) {
    if (gRunning) {
        log(@"Đang chạy");
        return;
    }
    if (!gSenderReady) {
        log(@"Chưa gắn hàm gửi tin, chưa gửi gì cả");
        return;
    }
    NSString *text = [D() stringForKey:kMessage] ?: @"";
    if (!text.length) {
        log(@"Chưa nhập nội dung tin nhắn");
        return;
    }
    NSMutableArray *queue = [NSMutableArray array];
    for (NSString *u in TTUsers()) {
        if (!TTSentToday(u)) [queue addObject:u];
    }
    if (!queue.count) {
        log(@"Hôm nay đã gửi đủ");
        return;
    }
    gRunning = YES;
    __block NSUInteger i = 0;
    __block void (^next)(void);
    next = ^{
        if (i >= queue.count) {
            gRunning = NO;
            log(@"Xong");
            next = nil;
            return;
        }
        NSString *u = queue[i++];
        if (TTSentToday(u)) {
            next();
            return;
        }
        TTMarkSent(u);
        TTSendMessage(u, text, ^(BOOL ok) {
            log([NSString stringWithFormat:@"%@: %@", u, ok ? @"đã gửi" : @"lỗi"]);
            double delay = 6 + arc4random_uniform(7);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                next();
            });
        });
    };
    next();
}

static NSArray<NSString *> *TTAppClassNames(void) {
    NSMutableArray *all = [NSMutableArray array];
    unsigned int ic = 0;
    const char **images = objc_copyImageNames(&ic);
    NSString *root = NSBundle.mainBundle.bundlePath;
    for (unsigned int i = 0; i < ic; i++) {
        NSString *p = [NSString stringWithUTF8String:images[i]];
        if (![p hasPrefix:root]) continue;
        unsigned int n = 0;
        const char **names = objc_copyClassNamesForImage(images[i], &n);
        for (unsigned int j = 0; j < n; j++) {
            [all addObject:[NSString stringWithUTF8String:names[j]]];
        }
        free(names);
    }
    free(images);
    return all;
}

static NSString *TTScanClasses(NSString *filter) {
    NSArray *keys = filter.length ? @[filter.lowercaseString] : @[@"conversation", @"message", @"chat", @"inbox", @"directmessage"];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *s in TTAppClassNames()) {
        NSString *l = s.lowercaseString;
        for (NSString *k in keys) {
            if ([l containsString:k]) {
                [hits addObject:s];
                break;
            }
        }
    }
    [hits sortUsingSelector:@selector(compare:)];
    NSUInteger total = hits.count;
    if (hits.count > 400) hits = [[hits subarrayWithRange:NSMakeRange(0, 400)] mutableCopy];
    return [NSString stringWithFormat:@"%lu class (hiện tối đa 400)\n%@", (unsigned long)total, [hits componentsJoinedByString:@"\n"]];
}

static NSString *TTDumpMethods(NSString *cls) {
    Class c = NSClassFromString(cls);
    if (!c) return @"Không tìm thấy class";
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) {
        [out addObject:[@"- " stringByAppendingString:NSStringFromSelector(method_getName(ms[i]))]];
    }
    free(ms);
    n = 0;
    Method *cm = class_copyMethodList(object_getClass(c), &n);
    for (unsigned int i = 0; i < n; i++) {
        [out addObject:[@"+ " stringByAppendingString:NSStringFromSelector(method_getName(cm[i]))]];
    }
    free(cm);
    if (out.count > 500) out = [[out subarrayWithRange:NSMakeRange(0, 500)] mutableCopy];
    return [out componentsJoinedByString:@"\n"];
}

static NSMutableString *gTraceLog;
static __weak id gSendController;

static void TTTraceAdd(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTraceLog) gTraceLog = [NSMutableString string];
        if (gTraceLog.length > 60000) [gTraceLog deleteCharactersInRange:NSMakeRange(0, 20000)];
        [gTraceLog appendFormat:@"%@\n", line];
    });
}

static NSString *TTShort(id o) {
    if (!o) return @"nil";
    NSString *d = nil;
    @try { d = [o description]; } @catch (...) { d = @"?"; }
    if (d.length > 300) d = [[d substringToIndex:300] stringByAppendingString:@"..."];
    return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([o class]), d];
}

static BOOL TTIsPlain(id o) {
    return [o isKindOfClass:NSString.class] || [o isKindOfClass:NSNumber.class] || [o isKindOfClass:NSDictionary.class] || [o isKindOfClass:NSArray.class] || [o isKindOfClass:NSClassFromString(@"NSBlock")];
}

static NSString *TTProps(id o) {
    NSMutableString *r = [NSMutableString string];
    int count = 0;
    for (Class c = [o class]; c && c != NSObject.class && count < 40; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        objc_property_t *ps = class_copyPropertyList(c, &n);
        for (unsigned int i = 0; i < n && count < 40; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(ps[i])];
            id v = nil;
            @try { v = [o valueForKey:name]; } @catch (...) { v = @"(loi)"; }
            [r appendFormat:@"    .%@ = %@\n", name, TTShort(v)];
            count++;
        }
        free(ps);
    }
    return r;
}

static void TTLogCall(NSString *name, id me, NSArray *args) {
    @try {
        Class sc = NSClassFromString(@"AWEIMSendMessageController");
        if (sc && [me isKindOfClass:sc]) gSendController = me;
        NSMutableString *s = [NSMutableString stringWithFormat:@"== %@\n  self %@\n", name, TTShort(me)];
        for (NSUInteger i = 0; i < args.count; i++) {
            id a = args[i] == NSNull.null ? nil : args[i];
            [s appendFormat:@"  arg%lu %@\n", (unsigned long)i, TTShort(a)];
            if (a && !TTIsPlain(a)) [s appendString:TTProps(a)];
        }
        TTTraceAdd(s);
    } @catch (...) {}
}

static BOOL TTHookVoid1(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a) {
        TTLogCall(name, me, @[a ?: NSNull.null]);
        o(me, s, a);
    }));
    return YES;
}

static BOOL TTHookVoid2(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id, id) = (void (*)(id, SEL, id, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a, id b) {
        TTLogCall(name, me, @[a ?: NSNull.null, b ?: NSNull.null]);
        o(me, s, a, b);
    }));
    return YES;
}

static BOOL TTHookVoid3(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    void (*o)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^(id me, id a, id b, id d) {
        TTLogCall(name, me, @[a ?: NSNull.null, b ?: NSNull.null, d ?: NSNull.null]);
        o(me, s, a, b, d);
    }));
    return YES;
}

static BOOL TTHookRet2(Class c, SEL s) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) return NO;
    id (*o)(id, SEL, id, id) = (id (*)(id, SEL, id, id))method_getImplementation(m);
    NSString *name = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(c), NSStringFromSelector(s)];
    method_setImplementation(m, imp_implementationWithBlock(^id(id me, id a, id b) {
        TTLogCall(name, me, @[a ?: NSNull.null, b ?: NSNull.null]);
        id r = o(me, s, a, b);
        TTTraceAdd([NSString stringWithFormat:@"  return %@", TTShort(r)]);
        return r;
    }));
    return YES;
}

static void TTInstallTrace(void) {
    static BOOL done = NO;
    if (done) {
        TTTraceAdd(@"Trace đã bật rồi");
        return;
    }
    done = YES;
    Class sc = NSClassFromString(@"AWEIMSendMessageController");
    Class qc = NSClassFromString(@"AWEIMQuickDMMessageSenderService");
    Class rc = NSClassFromString(@"AWEIMChatRoomMessageSender");
    NSArray *res = @[
        @(TTHookRet2(sc, @selector(sendMessage:conversation:))),
        @(TTHookVoid3(sc, @selector(p_sendMessage:toConversation:sentMessageDict:))),
        @(TTHookVoid2(sc, @selector(sendBatchMessages:completion:))),
        @(TTHookVoid1(qc, @selector(sendMessageWithParams:))),
        @(TTHookVoid1(rc, @selector(trySendMessage:))),
        @(TTHookVoid3(rc, @selector(trySendMessage:onCanContinueToSend:onDidGenerateMessageId:)))
    ];
    TTTraceAdd([NSString stringWithFormat:@"Đã bật trace, kết quả từng hook (1 là được, 0 là không thấy): %@", [res componentsJoinedByString:@" "]]);
}

static UIWindow *TTKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static UIButton *TTButton(NSString *title, CGRect f, id target, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:13];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:target action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UITextField *TTField(NSString *placeholder, CGRect f, NSString *text) {
    UITextField *t = [[UITextField alloc] initWithFrame:f];
    t.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    t.textColor = UIColor.whiteColor;
    t.font = [UIFont systemFontOfSize:14];
    t.layer.cornerRadius = 8;
    t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    t.returnKeyType = UIReturnKeyDone;
    t.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, f.size.height)];
    t.leftViewMode = UITextFieldViewModeAlways;
    t.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: UIColor.grayColor}];
    t.text = text;
    return t;
}

@interface TTPanelView : UIView <UITextViewDelegate>
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UITextField *msg;
@property (nonatomic, strong) UITextView *users;
@property (nonatomic, strong) UITextField *cls;
@property (nonatomic, strong) UITextView *out;
@end

@implementation TTPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    CGFloat w = frame.size.width;
    CGFloat h = frame.size.height;
    self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.97];
    self.layer.cornerRadius = 16;
    self.clipsToBounds = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 60, 24)];
    title.text = @"TT Panel";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [self addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 44, 8, 32, 32);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:close];

    UILabel *state = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, w - 90, 31)];
    state.text = @"Tự động gửi khi mở app";
    state.textColor = UIColor.whiteColor;
    state.font = [UIFont systemFontOfSize:15];
    [self addSubview:state];

    self.toggle = [[UISwitch alloc] init];
    self.toggle.center = CGPointMake(w - 16 - self.toggle.bounds.size.width / 2, 63);
    self.toggle.on = [D() boolForKey:kEnabled];
    [self.toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    [self addSubview:self.toggle];

    self.msg = TTField(@"Nội dung tin nhắn", CGRectMake(16, 88, w - 32, 36), [D() stringForKey:kMessage]);
    [self.msg addTarget:self action:@selector(msgChanged) forControlEvents:UIControlEventEditingChanged];
    [self.msg addTarget:self action:@selector(endEdit) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addSubview:self.msg];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 128, w - 32, 18)];
    hint.text = @"Danh sách username (mỗi dòng một người)";
    hint.textColor = UIColor.grayColor;
    hint.font = [UIFont systemFontOfSize:12];
    [self addSubview:hint];

    self.users = [[UITextView alloc] initWithFrame:CGRectMake(16, 148, w - 32, 100)];
    self.users.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    self.users.textColor = UIColor.whiteColor;
    self.users.font = [UIFont systemFontOfSize:14];
    self.users.layer.cornerRadius = 8;
    self.users.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.users.autocorrectionType = UITextAutocorrectionTypeNo;
    self.users.text = [D() stringForKey:kUsers] ?: @"";
    self.users.delegate = self;
    [self addSubview:self.users];

    CGFloat half = (w - 40) / 2;
    [self addSubview:TTButton(@"Chạy ngay", CGRectMake(16, 256, half, 36), self, @selector(runNow))];
    [self addSubview:TTButton(@"Ẩn bàn phím", CGRectMake(24 + half, 256, half, 36), self, @selector(endEdit))];

    self.cls = TTField(@"Tên class (Methods) hoặc từ khóa (Quét class)", CGRectMake(16, 300, w - 32, 36), nil);
    [self.cls addTarget:self action:@selector(endEdit) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addSubview:self.cls];

    CGFloat third = (w - 48) / 3;
    [self addSubview:TTButton(@"Quét class", CGRectMake(16, 344, third, 36), self, @selector(scan))];
    [self addSubview:TTButton(@"Methods", CGRectMake(24 + third, 344, third, 36), self, @selector(methods))];
    [self addSubview:TTButton(@"Sao chép", CGRectMake(32 + third * 2, 344, third, 36), self, @selector(copyOut))];

    [self addSubview:TTButton(@"Bật trace", CGRectMake(16, 388, half, 36), self, @selector(startTrace))];
    [self addSubview:TTButton(@"Xem trace", CGRectMake(24 + half, 388, half, 36), self, @selector(showTrace))];

    self.out = [[UITextView alloc] initWithFrame:CGRectMake(16, 432, w - 32, h - 432 - 12)];
    self.out.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1];
    self.out.textColor = [UIColor colorWithRed:0.5 green:1 blue:0.6 alpha:1];
    self.out.font = [UIFont fontWithName:@"Menlo" size:11];
    self.out.editable = NO;
    self.out.layer.cornerRadius = 8;
    [self addSubview:self.out];

    return self;
}

- (void)textViewDidChange:(UITextView *)tv {
    if (tv == self.users) [D() setObject:tv.text ?: @"" forKey:kUsers];
}

- (void)msgChanged {
    [D() setObject:self.msg.text ?: @"" forKey:kMessage];
}

- (void)toggleChanged {
    [D() setBool:self.toggle.isOn forKey:kEnabled];
}

- (void)endEdit {
    [self endEditing:YES];
}

- (void)runNow {
    [self endEditing:YES];
    self.out.text = @"";
    __weak TTPanelView *ws = self;
    TTRunDaily(^(NSString *s) {
        ws.out.text = [ws.out.text stringByAppendingFormat:@"%@\n", s];
    });
}

- (void)scan {
    [self endEditing:YES];
    self.out.text = TTScanClasses([self.cls.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
}

- (void)methods {
    [self endEditing:YES];
    NSString *name = [self.cls.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    self.out.text = TTDumpMethods(name);
}

- (void)startTrace {
    [self endEditing:YES];
    TTInstallTrace();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.out.text = gTraceLog ?: @"";
    });
}

- (void)showTrace {
    [self endEditing:YES];
    self.out.text = gTraceLog.length ? gTraceLog : @"Chưa có gì. Bật trace rồi tự gửi một tin nhắn thật trong chat.";
}

- (void)copyOut {
    UIPasteboard.generalPasteboard.string = self.out.text;
}

- (void)hide {
    [self endEditing:YES];
    self.hidden = YES;
}

@end

@interface TTPanelController : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) TTPanelView *panel;
+ (instancetype)shared;
- (void)install;
@end

@implementation TTPanelController

+ (instancetype)shared {
    static TTPanelController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [TTPanelController new]; });
    return c;
}

- (void)install {
    UIWindow *window = TTKeyWindow();
    if (!window || self.button) return;

    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.frame = CGRectMake(12, 120, 44, 44);
    self.button.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
    self.button.layer.cornerRadius = 22;
    [self.button setTitle:@"⚙" forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(toggleUI) forControlEvents:UIControlEventTouchUpInside];
    [self.button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [window addSubview:self.button];

    CGFloat w = MIN(340, window.bounds.size.width - 24);
    CGFloat h = MIN(600, window.bounds.size.height - 80);
    self.panel = [[TTPanelView alloc] initWithFrame:CGRectMake((window.bounds.size.width - w) / 2, 40, w, h)];
    self.panel.hidden = YES;
    [window addSubview:self.panel];
}

- (void)toggleUI {
    self.panel.hidden = !self.panel.hidden;
    [self.panel.superview bringSubviewToFront:self.panel];
    [self.button.superview bringSubviewToFront:self.button];
}

- (void)drag:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

@end

%ctor {
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[TTPanelController shared] install];
        });
        static dispatch_once_t autoOnce;
        dispatch_once(&autoOnce, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([D() boolForKey:kEnabled]) {
                    TTRunDaily(^(NSString *s) {
                        NSLog(@"[TTPanel] %@", s);
                    });
                }
            });
        });
    }];
}
