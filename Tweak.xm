#include <UIKit/UIKit.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/QuartzCore.h>
#include <stdarg.h>
#import <objc/runtime.h>

@interface FDFloatingController : NSObject
+ (instancetype)shared;
- (void)install;
- (void)remove;
- (void)toggle;
- (void)updateStatus:(NSString *)status;
@end

@interface FDCoordinator : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (void)candidateFound:(id)object source:(NSString *)source;
- (void)redPacketTapped;
@end

static NSString * const FDEnabledKey = @"fudai.enabled";
static NSString * const FDDelayKey = @"fudai.delayMinutes";
static NSString * const FDCooldownKey = @"fudai.cooldownSeconds";
static NSString * const FDDailyLimitKey = @"fudai.dailyLimit";
static NSString * const FDDebugKey = @"fudai.debug";

static BOOL FDEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:FDEnabledKey] == nil) [d setBool:NO forKey:FDEnabledKey];
    return [d boolForKey:FDEnabledKey];
}

static NSTimeInterval FDNumber(NSString *key, double fallback) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:key] == nil) [d setDouble:fallback forKey:key];
    return [d doubleForKey:key];
}

static void FDLog(NSString *format, ...) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:FDDebugKey]) return;
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[FuDai] %@", message);
}

@implementation FDCoordinator {
    dispatch_source_t _timer;
    NSInteger _dailyCount;
    NSDate *_day;
    NSDate *_lastTrigger;
    BOOL _running;
    BOOL _triggering;
}

+ (instancetype)shared { static FDCoordinator *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

- (instancetype)init {
    if ((self = [super init])) {
        _day = [NSDate date];
        _dailyCount = 0;
    }
    return self;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_running) return;
        self->_running = YES;
        [self schedulePoll];
        [[FDFloatingController shared] updateStatus:@"运行中 · 等待福袋"];
        FDLog(@"state=Idle");
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_running = NO;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        [[FDFloatingController shared] updateStatus:@"已暂停"];
        FDLog(@"state=Disabled");
    });
}

- (void)schedulePoll {
    if (!self->_running) return;
    if (self->_timer) dispatch_source_cancel(self->_timer);
    self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf poll]; });
    dispatch_resume(self->_timer);
}

- (void)poll {
    if (!self->_running || !FDEnabled()) return;
    NSDate *now = [NSDate date];
    if ([[NSCalendar currentCalendar] compareDate:now toDate:self->_day toUnitGranularity:NSCalendarUnitDay] != NSOrderedSame) { self->_day = now; self->_dailyCount = 0; }
    NSInteger limit = (NSInteger)FDNumber(FDDailyLimitKey, 30);
    if (limit > 0 && self->_dailyCount >= limit) { [[FDFloatingController shared] updateStatus:@"今日上限已到"]; return; }
    if (self->_lastTrigger && [now timeIntervalSinceDate:self->_lastTrigger] < FDNumber(FDCooldownKey, 20)) return;
}

- (void)candidateFound:(id)object source:(NSString *)source {
    if (!self->_running || !FDEnabled() || !object || self->_triggering) return;
    NSDate *now = [NSDate date];
    if (self->_lastTrigger && [now timeIntervalSinceDate:self->_lastTrigger] < FDNumber(FDCooldownKey, 20)) return;
    self->_triggering = YES;
    FDLog(@"state=CandidateFound source=%@ class=%@", source, NSStringFromClass([object class]));
    [[FDFloatingController shared] updateStatus:@"发现福袋 · 等待触发"];
    NSTimeInterval delay = FDNumber(FDDelayKey, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * 60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_triggering = NO;
        if (!self->_running || !FDEnabled()) return;
        self->_lastTrigger = [NSDate date];
        self->_dailyCount += 1;
        [[FDFloatingController shared] updateStatus:@"已触发 · 冷却中"];
        FDLog(@"state=Triggering count=%ld", (long)self->_dailyCount);
    });
}

- (void)redPacketTapped { self->_lastTrigger = [NSDate date]; }
@end

@implementation FDFloatingController {
    UIWindow *_window;
    UIButton *_button;
    UILabel *_label;
    UIPanGestureRecognizer *_pan;
}

+ (instancetype)shared { static FDFloatingController *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

// 修复点1: 原来靠 hook UIApplication 的 delegate 方法触发，永远不会被调用。
// 现在由 UIApplicationDidFinishLaunchingNotification 触发，且场景未就绪时自动重试。
- (void)install {
    [self installWithRetry:15];
}

- (void)installWithRetry:(NSInteger)retries {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_window) return;
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
        }
        if (!scene) {
            FDLog(@"install: window scene not ready, retries left=%ld", (long)retries);
            if (retries > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [self installWithRetry:retries - 1];
                });
            }
            return;
        }
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(12, 140, 116, 44);
        w.windowLevel = UIWindowLevelAlert - 1;
        w.backgroundColor = UIColor.clearColor;
        UIView *box = [[UIView alloc] initWithFrame:w.bounds];
        box.backgroundColor = [UIColor colorWithWhite:0 alpha:.78];
        box.layer.cornerRadius = 22;
        self->_button = [UIButton buttonWithType:UIButtonTypeSystem];
        self->_button.frame = box.bounds;
        [self->_button setTitle:(FDEnabled() ? @"福袋 · 开" : @"福袋 · 关") forState:UIControlStateNormal];
        [self->_button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [self->_button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:self->_button];
        self->_pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [box addGestureRecognizer:self->_pan];
        [w addSubview:box];
        w.hidden = NO;
        self->_window = w;
        FDLog(@"floating window installed");
    });
}

- (void)remove {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_window.hidden = YES;
        self->_window = nil;
    });
}

- (void)toggle {
    BOOL enabled = !FDEnabled();
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FDEnabledKey];
    [self->_button setTitle:(enabled ? @"福袋 · 开" : @"福袋 · 关") forState:UIControlStateNormal];
    if (enabled) [[FDCoordinator shared] start]; else [[FDCoordinator shared] stop];
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_button) [self->_button setTitle:status forState:UIControlStateNormal];
    });
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:self->_window];
    self->_window.center = CGPointMake(self->_window.center.x + p.x, self->_window.center.y + p.y);
    [g setTranslation:CGPointZero inView:self->_window];
}
@end

#pragma mark - Douyin hooks（分组定义，运行时确认类/方法存在后才 hook）

%group GComponentTapped
%hook AWEIMDouyinRedPacketComponent
- (void)redPacketDidTapped {
    [[FDCoordinator shared] redPacketTapped];
    %orig;
}
%end
%end

%group GComponentOpen2
%hook AWEIMDouyinRedPacketComponent
- (void)openRedPacketWithOrderId:(id)orderId completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"openRedPacketWithOrderId:completion:"];
    %orig;
}
%end
%end

%group GComponentOpen3
%hook AWEIMDouyinRedPacketComponent
- (void)openRedPacketWithOrderId:(id)orderId extParams:(id)params completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"openRedPacketWithOrderId:extParams:completion:"];
    %orig;
}
%end
%end

%group GDataFetch2
%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"fetchRedPacketInfoWithOrderId:completion:"];
    %orig;
}
%end
%end

%group GDataFetch3
%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId params:(id)params completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"fetchRedPacketInfoWithOrderId:params:completion:"];
    %orig;
}
%end
%end

%group GLuckyCat
%hook AWELuckyCatBannerView
- (void)didMoveToWindow {
    %orig;
    UIView *banner = (UIView *)self;
    if (banner.window && !banner.hidden) {
        [[FDCoordinator shared] candidateFound:self source:@"AWELuckyCatBannerView"];
    }
}
%end
%end

// 修复点2: 每个 hook 独立分组 + 存在性检查，抖音改版后某个方法不存在就跳过，
// 不再因为签名不匹配导致 %orig 传错参数而崩溃。
static BOOL gCompTapped, gCompOpen2, gCompOpen3, gDataFetch2, gDataFetch3, gLuckyCat;

// 调试：把运行时加载的类中，名字含红包/福袋关键词的类及其全部方法名写入
// <App>/Documents/fudai_dump.txt，用于确认当前抖音版本的真实类名/selector。
static void FDDumpRuntimeInfo(void) {
    @autoreleasepool {
        NSArray *keywords = @[@"RedPacket", @"redPacket", @"LuckyBag", @"luckyBag",
                              @"HongBao", @"hongbao", @"Packet", @"Lucky", @"Bag"];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"totalClasses=%u\n", count];
        [out appendFormat:@"targetClass AWEIMDouyinRedPacketComponent = %@\n",
            NSClassFromString(@"AWEIMDouyinRedPacketComponent") ? @"FOUND" : @"MISSING"];
        [out appendFormat:@"targetClass AWEIMDouyinRedPacketDataManager = %@\n",
            NSClassFromString(@"AWEIMDouyinRedPacketDataManager") ? @"FOUND" : @"MISSING"];
        [out appendFormat:@"targetClass AWELuckyCatBannerView = %@\n",
            NSClassFromString(@"AWELuckyCatBannerView") ? @"FOUND" : @"MISSING"];
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            BOOL hit = NO;
            for (NSString *kw in keywords) {
                if ([name containsString:kw]) { hit = YES; break; }
            }
            if (!hit) continue;
            [out appendFormat:@"\n=== %@ ===\n", name];
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(classes[i], &mcount);
            for (unsigned int j = 0; j < mcount; j++) {
                [out appendFormat:@"  %s\n", sel_getName(method_getName(methods[j]))];
            }
            free(methods);
        }
        free(classes);
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *file = [paths.firstObject stringByAppendingPathComponent:@"fudai_dump.txt"];
        NSError *err = nil;
        BOOL ok = [out writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:&err];
        NSLog(@"[FuDai] runtime dump %@ -> %@ (%lu bytes)", ok ? @"OK" : err, file, (unsigned long)out.length);
    }
}

static void FDInitHooks(void) {
    Class comp = NSClassFromString(@"AWEIMDouyinRedPacketComponent");
    if (!gCompTapped && comp && [comp instancesRespondToSelector:@selector(redPacketDidTapped)]) {
        gCompTapped = YES; %init(GComponentTapped);
        FDLog(@"hooked redPacketDidTapped");
    }
    if (!gCompOpen2 && comp && [comp instancesRespondToSelector:@selector(openRedPacketWithOrderId:completion:)]) {
        gCompOpen2 = YES; %init(GComponentOpen2);
        FDLog(@"hooked openRedPacketWithOrderId:completion:");
    }
    if (!gCompOpen3 && comp && [comp instancesRespondToSelector:@selector(openRedPacketWithOrderId:extParams:completion:)]) {
        gCompOpen3 = YES; %init(GComponentOpen3);
        FDLog(@"hooked openRedPacketWithOrderId:extParams:completion:");
    }
    Class dm = NSClassFromString(@"AWEIMDouyinRedPacketDataManager");
    if (!gDataFetch2 && dm && [dm instancesRespondToSelector:@selector(fetchRedPacketInfoWithOrderId:completion:)]) {
        gDataFetch2 = YES; %init(GDataFetch2);
        FDLog(@"hooked fetchRedPacketInfoWithOrderId:completion:");
    }
    if (!gDataFetch3 && dm && [dm instancesRespondToSelector:@selector(fetchRedPacketInfoWithOrderId:params:completion:)]) {
        gDataFetch3 = YES; %init(GDataFetch3);
        FDLog(@"hooked fetchRedPacketInfoWithOrderId:params:completion:");
    }
    Class lucky = NSClassFromString(@"AWELuckyCatBannerView");
    if (!gLuckyCat && lucky) {
        gLuckyCat = YES; %init(GLuckyCat);
        FDLog(@"hooked AWELuckyCatBannerView");
    }
}

%ctor {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            FDEnabledKey: @NO,
            FDDelayKey: @0,
            FDCooldownKey: @20,
            FDDailyLimitKey: @30,
            FDDebugKey: @NO
        }];
        NSLog(@"[FuDai] loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier);

        // 进程启动时先尝试一次（主二进制里的类此时已可解析）
        FDInitHooks();

        // 修复点1: 用启动完成通知代替错误的 UIApplication hook
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [[FDFloatingController shared] install];
            if (FDEnabled()) [[FDCoordinator shared] start];
            // 直播间等模块是懒加载的框架，延迟多试几次（标志位保证不会重复 hook）
            for (int i = 1; i <= 6; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FDInitHooks();
                });
            }
            // 调试模式：启动 20 秒后 dump 一次运行时类信息（等懒加载框架就绪）
            if ([NSUserDefaults.standardUserDefaults boolForKey:FDDebugKey]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    FDDumpRuntimeInfo();
                });
            }
        }];
    }
}
