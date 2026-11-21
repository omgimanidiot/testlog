// TTMTrace - giai đoạn 1: ghi lại cách TikTok 47.8.0 gửi tin nhắn.
// Không gửi gì, không sửa hành vi: chỉ quan sát và ghi log.
// Không cần Substrate/Theos: dùng ObjC runtime thuần (msgForward + forwardInvocation).
//
// Cách dùng: xem README.md. Dùng tài khoản phụ.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>

static NSString *const kLogName = @"ttm_trace.log";
static NSString *const kAliasPrefix = @"ttm_orig_";
static dispatch_queue_t gLogQ;
static NSMutableSet<NSString *> *gHookedKeys;                 // "Class|selector"
static NSMutableDictionary<NSString *, NSValue *> *gOrigForward; // Class -> IMP forwardInvocation: gốc
static NSRegularExpression *gMethodRE;

// Class ứng viên lấy từ phân tích tĩnh MusicallyCore 47.8.0.
static NSArray<NSString *> *Candidates(void) {
    return @[
        @"AWEIMSendMessageController",
        @"AWEIMSendMessageContext",
        @"AWEIMSendMessageParam",
        @"AWEIMSendMessageModel",
        @"AWEIMQuickDMMessageSenderService",
        @"AWEIMChatRoomMessageSender",
        @"AWEIMHalfPageReplyMessageSender",
    ];
}

#pragma mark - Log

static NSString *LogPath(void) {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        p = [dir stringByAppendingPathComponent:kLogName];
    });
    return p;
}

static void TTMLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TTMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    dispatch_async(gLogQ, ^{
        @try {
            NSString *path = LogPath();
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
                return;
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - Mô tả giá trị (an toàn, không gọi code có tác dụng phụ)

static NSString *Trunc(NSString *s, NSUInteger max) {
    return s.length > max ? [[s substringToIndex:max] stringByAppendingString:@"…"] : s;
}

static NSString *DescribeShallow(id o) {
    if (!o) return @"nil";
    @try {
        if ([o isKindOfClass:NSString.class])
            return [NSString stringWithFormat:@"NSString(%lu) \"%@\"", (unsigned long)[o length], Trunc(o, 200)];
        if ([o isKindOfClass:NSNumber.class])
            return [NSString stringWithFormat:@"NSNumber %@", o];
        if ([o isKindOfClass:NSData.class])
            return [NSString stringWithFormat:@"NSData(%lu bytes)", (unsigned long)[o length]];
        if ([o isKindOfClass:NSDictionary.class] || [o isKindOfClass:NSArray.class])
            return [NSString stringWithFormat:@"%s %@", object_getClassName(o), Trunc([o description], 400)];
        return [NSString stringWithFormat:@"<%s %p>", object_getClassName(o), o];
    } @catch (__unused NSException *e) {
        return @"<describe failed>";
    }
}

// Liệt kê property (một cấp) của đối tượng IM để thấy cấu trúc Context/Param/Model.
static NSString *DumpProps(id o) {
    NSMutableString *out = [NSMutableString string];
    int budget = 30;
    Class c = object_getClass(o);
    while (c && c != NSObject.class && budget > 0) {
        unsigned n = 0;
        objc_property_t *ps = class_copyPropertyList(c, &n);
        for (unsigned i = 0; i < n && budget > 0; i++) {
            const char *attr = property_getAttributes(ps[i]);
            if (!attr || attr[0] != 'T') continue;
            char t = attr[1];
            if (t == '@' && attr[2] == '?') continue; // bỏ block
            if (!strchr("@BcCsSiIlLqQdf", t)) continue; // bỏ struct, pointer...
            NSString *name = @(property_getName(ps[i]));
            @try {
                id v = [o valueForKey:name];
                [out appendFormat:@"%@=%@; ", name, DescribeShallow(v)];
                budget--;
            } @catch (__unused NSException *e) {}
        }
        free(ps);
        c = class_getSuperclass(c);
    }
    return out;
}

static BOOL IsInteresting(id o) {
    const char *n = object_getClassName(o);
    return strncmp(n, "AWEIM", 5) == 0 || strncmp(n, "IM", 2) == 0;
}

static NSString *DescribeArg(NSInvocation *inv, NSUInteger idx) {
    const char *enc = [inv.methodSignature getArgumentTypeAtIndex:idx];
    while (*enc && strchr("rnNoORV", *enc)) enc++;
    switch (*enc) {
        case '@': {
            if (enc[1] == '?') {
                void *b = NULL;
                [inv getArgument:&b atIndex:(NSInteger)idx];
                return [NSString stringWithFormat:@"<block %p>", b];
            }
            __unsafe_unretained id o = nil;
            [inv getArgument:&o atIndex:(NSInteger)idx];
            NSString *d = DescribeShallow(o);
            if (o && IsInteresting(o))
                d = [d stringByAppendingFormat:@"\n          props: %@", DumpProps(o)];
            return d;
        }
        case 'B': { bool v = false; [inv getArgument:&v atIndex:(NSInteger)idx]; return v ? @"YES" : @"NO"; }
        case 'c': { char v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%d", v]; }
        case 'C': { unsigned char v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%u", v]; }
        case 's': { short v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%d", v]; }
        case 'S': { unsigned short v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%u", v]; }
        case 'i': { int v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%d", v]; }
        case 'I': { unsigned v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%u", v]; }
        case 'l': case 'q': { long long v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%lld", v]; }
        case 'L': case 'Q': { unsigned long long v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%llu", v]; }
        case 'd': { double v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%g", v]; }
        case 'f': { float v = 0; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"%g", v]; }
        case '#': { Class v = Nil; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"Class %@", NSStringFromClass(v)]; }
        case ':': { SEL v = NULL; [inv getArgument:&v atIndex:(NSInteger)idx]; return [NSString stringWithFormat:@"SEL %@", NSStringFromSelector(v)]; }
        default:  return [NSString stringWithFormat:@"<kiểu %s>", enc];
    }
}

#pragma mark - Hook bằng msgForward

static void TTMForward(id self, SEL _cmd, NSInvocation *inv) {
    SEL sel = inv.selector;
    NSString *sn = NSStringFromSelector(sel);

    Class c = object_getClass(self);
    while (c) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(c), sn];
        BOOL ours;
        @synchronized (gHookedKeys) { ours = [gHookedKeys containsObject:key]; }
        if (ours) {
            NSMutableString *log = [NSMutableString stringWithFormat:@"[CALL] -[%s %@]  (hook ở %@, thread %@)",
                                    object_getClassName(self), sn, NSStringFromClass(c),
                                    NSThread.isMainThread ? @"main" : @"bg"];
            NSUInteger argc = inv.methodSignature.numberOfArguments;
            for (NSUInteger i = 2; i < argc; i++)
                [log appendFormat:@"\n      arg%lu = %@", (unsigned long)(i - 2), DescribeArg(inv, i)];
            NSArray *stack = NSThread.callStackSymbols;
            NSUInteger lim = MIN((NSUInteger)10, stack.count);
            for (NSUInteger i = 2; i < lim; i++) [log appendFormat:@"\n      at %@", stack[i]];
            TTMLog(@"%@", log);

            inv.selector = NSSelectorFromString([kAliasPrefix stringByAppendingString:sn]);
            [inv invoke];
            return;
        }
        c = class_getSuperclass(c);
    }

    // Không phải method của ta: chuyển cho forwardInvocation: gốc.
    Class cc = object_getClass(self);
    while (cc) {
        NSValue *v;
        @synchronized (gHookedKeys) { v = gOrigForward[NSStringFromClass(cc)]; }
        void *imp = v.pointerValue;
        if (imp) {
            ((void (*)(id, SEL, NSInvocation *))imp)(self, _cmd, inv);
            return;
        }
        cc = class_getSuperclass(cc);
    }
    [self doesNotRecognizeSelector:sel];
}

static BOOL ShouldHook(NSString *name) {
    if ([name hasPrefix:kAliasPrefix] || [name hasPrefix:@"."]) return NO;
    static NSSet *deny;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        deny = [NSSet setWithArray:@[@"forwardInvocation:", @"methodSignatureForSelector:",
                                     @"respondsToSelector:", @"dealloc", @"forwardingTargetForSelector:"]];
    });
    if ([deny containsObject:name]) return NO;
    return [gMethodRE numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] > 0;
}

static void HookClass(Class cls) {
    NSString *cn = NSStringFromClass(cls);
    @synchronized (gHookedKeys) {
        if (!gOrigForward[cn]) {
            Method fm = class_getInstanceMethod(cls, @selector(forwardInvocation:));
            IMP orig = fm ? method_getImplementation(fm) : NULL;
            gOrigForward[cn] = [NSValue valueWithPointer:(void *)orig];
            class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)TTMForward, "v@:@");
        }
    }
    unsigned n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned i = 0; i < n; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *sn = NSStringFromSelector(sel);
        if (!ShouldHook(sn)) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", cn, sn];
        BOOL fresh = NO;
        @synchronized (gHookedKeys) {
            if (![gHookedKeys containsObject:key]) { [gHookedKeys addObject:key]; fresh = YES; }
        }
        if (!fresh) continue;
        const char *te = method_getTypeEncoding(ms[i]);
        SEL alias = NSSelectorFromString([kAliasPrefix stringByAppendingString:sn]);
        class_addMethod(cls, alias, method_getImplementation(ms[i]), te);
        method_setImplementation(ms[i], (IMP)_objc_msgForward);
        TTMLog(@"[hook] -[%@ %@]  type=%s", cn, sn, te ? te : "?");
    }
    free(ms);
}

static void HookAll(void) {
    for (NSString *name in Candidates()) {
        Class cls = NSClassFromString(name);
        if (!cls) { TTMLog(@"[miss] không thấy class %@", name); continue; }
        HookClass(cls);
    }
}

// Ghi tên các class AWEIM*Send*/Sender khác để lần sau mở rộng danh sách ứng viên.
static void LogOtherSenderClasses(void) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^AWEIM.*(Send|Sender)"
                                                                        options:0 error:nil];
    unsigned n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableArray *names = [NSMutableArray array];
    NSSet *cand = [NSSet setWithArray:Candidates()];
    for (unsigned i = 0; i < n; i++) {
        NSString *cn = NSStringFromClass(all[i]);
        if ([cand containsObject:cn]) continue;
        if ([re numberOfMatchesInString:cn options:0 range:NSMakeRange(0, cn.length)]) [names addObject:cn];
    }
    free(all);
    [names sortUsingSelector:@selector(compare:)];
    TTMLog(@"[classes] %lu class AWEIM*Send* khác: %@", (unsigned long)names.count,
           [names componentsJoinedByString:@", "]);
}

static void LogImages(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "MusicallyCore"))
            TTMLog(@"[image] %s slide=0x%lx", nm, (unsigned long)_dyld_get_image_vmaddr_slide(i));
    }
}

#pragma mark - Nút MARK / LOG

static UIWindow *KeyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

@interface TTMHelper : NSObject
+ (void)mark;
+ (void)share:(UIButton *)sender;
@end

@implementation TTMHelper
+ (void)mark {
    TTMLog(@"========== MARK (người dùng bấm) ==========");
}
+ (void)share:(UIButton *)sender {
    dispatch_async(gLogQ, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL fileURLWithPath:LogPath()];
            if (![NSFileManager.defaultManager fileExistsAtPath:LogPath()]) return;
            UIViewController *vc = KeyWindow().rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            a.popoverPresentationController.sourceView = sender;
            [vc presentViewController:a animated:YES completion:nil];
        });
    });
}
@end

static void InstallButtons(int attempt) {
    UIWindow *w = KeyWindow();
    if (!w) {
        if (attempt < 15)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ InstallButtons(attempt + 1); });
        return;
    }
    if ([w viewWithTag:0x77AA01]) return;
    NSArray *titles = @[@"MARK", @"LOG"];
    SEL acts[2] = { @selector(mark), @selector(share:) };
    for (int i = 0; i < 2; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = 0x77AA01 + i;
        b.frame = CGRectMake(w.safeAreaInsets.left + 8, w.safeAreaInsets.top + 60 + i * 40, 56, 32);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        b.layer.cornerRadius = 8;
        [b addTarget:TTMHelper.class action:acts[i] forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:b];
    }
}

#pragma mark - Khởi tạo

__attribute__((constructor)) static void TTMInit(void) {
    @autoreleasepool {
        gLogQ = dispatch_queue_create("ttm.log", DISPATCH_QUEUE_SERIAL);
        gHookedKeys = [NSMutableSet set];
        gOrigForward = [NSMutableDictionary dictionary];
        gMethodRE = [NSRegularExpression regularExpressionWithPattern:@"send|submit|enqueue|prepare|dispatch|create.*message|build.*message"
                                                              options:NSRegularExpressionCaseInsensitive error:nil];

        // Giữ file log dưới ~8 MB.
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:LogPath() error:nil];
        if ([attrs fileSize] > 8 * 1024 * 1024) [NSFileManager.defaultManager removeItemAtPath:LogPath() error:nil];

        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        TTMLog(@"=== TTMTrace bắt đầu | %@ %@ (%@) ===", info[@"CFBundleIdentifier"],
               info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]);
        LogImages();
        HookAll();

        // Lặp lại sau vài giây phòng class nạp muộn; hàm idempotent nhờ gHookedKeys.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            HookAll();
            LogOtherSenderClasses();
            InstallButtons(0);
        });
    }
}
