#include <UIKit/UIKit.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/QuartzCore.h>
#include <stdarg.h>

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
    if ([d objectForKey:FDEnabledKey] == nil) [d setBool:YES forKey:FDEnabledKey];
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
        if (_running) return;
        _running = YES;
        [self schedulePoll];
        [[FDFloatingController shared] updateStatus:@"运行中 · 等待福袋"];
        FDLog(@"state=Idle");
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        _running = NO;
        if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
        [[FDFloatingController shared] updateStatus:@"已暂停"];
        FDLog(@"state=Disabled");
    });
}

- (void)schedulePoll {
    if (!_running) return;
    if (_timer) dispatch_source_cancel(_timer);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf poll]; });
    dispatch_resume(_timer);
}

- (void)poll {
    if (!_running || !FDEnabled()) return;
    NSDate *now = [NSDate date];
    if ([[NSCalendar currentCalendar] compareDate:now toDate:_day toUnitGranularity:NSCalendarUnitDay] != NSOrderedSame) { _day=now; _dailyCount=0; }
    NSInteger limit = (NSInteger)FDNumber(FDDailyLimitKey, 30);
    if (limit > 0 && _dailyCount >= limit) { [[FDFloatingController shared] updateStatus:@"今日上限已到"]; return; }
    if (_lastTrigger && [now timeIntervalSinceDate:_lastTrigger] < FDNumber(FDCooldownKey, 20)) return;
}

- (void)candidateFound:(id)object source:(NSString *)source {
    if (!_running || !FDEnabled() || !object || _triggering) return;
    NSDate *now = [NSDate date];
    if (_lastTrigger && [now timeIntervalSinceDate:_lastTrigger] < FDNumber(FDCooldownKey, 20)) return;
    _triggering = YES;
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

- (void)redPacketTapped { _lastTrigger = [NSDate date]; }
@end

@implementation FDFloatingController {
    UIWindow *_window;
    UIButton *_button;
    UILabel *_label;
    UIPanGestureRecognizer *_pan;
}
+ (instancetype)shared { static FDFloatingController *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (void)install {
    if (_window || !UIApplication.sharedApplication) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_window) return;
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) { scene=(UIWindowScene *)s; break; }
        self->_window = [[UIWindow alloc] initWithWindowScene:scene];
        self->_window.frame = CGRectMake(12, 140, 116, 44);
        self->_window.windowLevel = UIWindowLevelAlert - 1;
        self->_window.backgroundColor = UIColor.clearColor;
        self->_window.hidden = NO;
        UIView *box = [[UIView alloc] initWithFrame:self->_window.bounds]; box.backgroundColor=[UIColor colorWithWhite:0 alpha:.78]; box.layer.cornerRadius=22;
        self->_button=[UIButton buttonWithType:UIButtonTypeSystem]; self->_button.frame=box.bounds; [self->_button setTitle:@"福袋 · 开" forState:UIControlStateNormal]; [self->_button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; [self->_button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside]; [box addSubview:self->_button];
        self->_pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]; [box addGestureRecognizer:self->_pan];
        [self->_window addSubview:box];
    });
}
- (void)remove { dispatch_async(dispatch_get_main_queue(), ^{ self->_window.hidden=YES; self->_window=nil; }); }
- (void)toggle { BOOL enabled = !FDEnabled(); [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FDEnabledKey]; if (enabled) [[FDCoordinator shared] start]; else [[FDCoordinator shared] stop]; }
- (void)updateStatus:(NSString *)status { dispatch_async(dispatch_get_main_queue(), ^{ if (self->_button) [self->_button setTitle:status forState:UIControlStateNormal]; }); }
- (void)pan:(UIPanGestureRecognizer *)g { CGPoint p=[g translationInView:_window]; _window.center=CGPointMake(_window.center.x+p.x,_window.center.y+p.y); [g setTranslation:CGPointZero inView:_window]; }
@end

%hook UIApplication
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL result = %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [[FDFloatingController shared] install]; if (FDEnabled()) [[FDCoordinator shared] start]; });
    return result;
}
%end

%hook AWEIMDouyinRedPacketComponent
- (void)redPacketDidTapped {
    [[FDCoordinator shared] redPacketTapped];
    %orig();
}
- (void)openRedPacketWithOrderId:(id)orderId completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"openRedPacketWithOrderId:completion:"];
    %orig(orderId, completion);
}
- (void)openRedPacketWithOrderId:(id)orderId extParams:(id)params completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"openRedPacketWithOrderId:extParams:completion:"];
    %orig(orderId, params, completion);
}
%end

%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"fetchRedPacketInfoWithOrderId:completion:"];
    %orig(orderId, completion);
}
- (void)fetchRedPacketInfoWithOrderId:(id)orderId params:(id)params completion:(id)completion {
    [[FDCoordinator shared] candidateFound:self source:@"fetchRedPacketInfoWithOrderId:params:completion:"];
    %orig(orderId, params, completion);
}
%end

%hook AWELuckyCatBannerView
- (void)didMoveToWindow { %orig; if (self.window && self.isHidden == NO) [[FDCoordinator shared] candidateFound:self source:@"AWELuckyCatBannerView"]; }
%end

%ctor {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{FDEnabledKey:@YES, FDDelayKey:@0, FDCooldownKey:@20, FDDailyLimitKey:@30, FDDebugKey:@NO}];
        FDLog(@"loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier);
    }
}
