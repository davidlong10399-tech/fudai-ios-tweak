#include <UIKit/UIKit.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/QuartzCore.h>
#include <stdarg.h>
#import <objc/runtime.h>

// 0.4.0: 真正的触发引擎。
// 旧版只监听私聊红包类并记账，从未执行任何抢取动作，且直播福袋不经过那些类。
// 新版按 Android 版同构思路：在进程内扫描视图树，按文字找到"福袋"入口并点击，
// 再在弹出的面板里点击"参与/领取/开"类按钮，然后进入冷却。不依赖具体类名。

@interface FDFloatingController : NSObject
+ (instancetype)shared;
- (void)install;
- (void)updateStatus:(NSString *)status;
- (NSArray<UIWindow *> *)fdWindows;
- (BOOL)ownsKeyWindow;
@end

@interface FDCoordinator : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (NSInteger)dailyCount;
- (void)redPacketTapped;
@end

static NSString * const FDEnabledKey    = @"fudai.enabled";
static NSString * const FDDelayKey      = @"fudai.delayMinutes";
static NSString * const FDCooldownKey   = @"fudai.cooldownSeconds";
static NSString * const FDDailyLimitKey = @"fudai.dailyLimit";
static NSString * const FDDebugKey      = @"fudai.debug";
static NSString * const FDKeywordKey    = @"fudai.keywords";

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

#pragma mark - 点击工具：UIControl 直接派发，手势视图调用其 action

static BOOL FDInvokeGestureTargets(UIGestureRecognizer *gr) {
    BOOL fired = NO;
    @try {
        NSArray *containers = [gr valueForKey:@"_targets"];
        for (id container in containers) {
            @try {
                id target = [container valueForKey:@"_target"];
                SEL action = NULL;
                id raw = [container valueForKey:@"_action"];
                if ([raw isKindOfClass:[NSString class]]) {
                    action = NSSelectorFromString(raw);
                } else if ([raw isKindOfClass:[NSValue class]]) {
                    action = (SEL)[(NSValue *)raw pointerValue];
                }
                if (target && action) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [target performSelector:action withObject:gr];
                    #pragma clang diagnostic pop
                    fired = YES;
                    FDLog(@"tap: gesture action fired on %@", NSStringFromClass([target class]));
                }
            } @catch (NSException *e) {
                FDLog(@"tap: gesture container exception %@", e);
            }
        }
    } @catch (NSException *e) {
        FDLog(@"tap: gesture targets exception %@", e);
    }
    return fired;
}

@interface FDTap : NSObject
+ (BOOL)tapView:(UIView *)view;
@end

@implementation FDTap
// 从命中视图开始向上找可点击对象（先 UIControl 后手势），最多 6 层
+ (BOOL)tapView:(UIView *)view {
    UIView *v = view;
    for (int level = 0; level < 6 && v; level++) {
        @try {
            if ([v isKindOfClass:UIControl.class]) {
                UIControl *c = (UIControl *)v;
                if (c.enabled && c.userInteractionEnabled && !c.hidden && c.alpha > 0.1) {
                    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                    FDLog(@"tap: UIControl %@ level=%d", NSStringFromClass([c class]), level);
                    return YES;
                }
            }
            for (UIGestureRecognizer *gr in v.gestureRecognizers) {
                if ([gr isKindOfClass:UITapGestureRecognizer.class] &&
                    gr.state == UIGestureRecognizerStatePossible &&
                    gr.enabled && v.userInteractionEnabled) {
                    if (FDInvokeGestureTargets(gr)) return YES;
                }
            }
        } @catch (NSException *e) {
            FDLog(@"tap: level %d exception %@", level, e);
        }
        v = v.superview;
    }
    FDLog(@"tap: no tappable target for %@", NSStringFromClass([view class]));
    return NO;
}
@end

#pragma mark - 视图扫描：按文字匹配可见 UILabel（UIButton 的 titleLabel 也是 UILabel）

static BOOL FDTextMatches(NSString *text, NSArray<NSString *> *contains, NSArray<NSString *> *exact, NSInteger maxLen) {
    if (![text isKindOfClass:NSString.class] || text.length == 0 || (NSInteger)text.length > maxLen) return NO;
    for (NSString *e in exact) {
        if ([text compare:e options:NSCaseInsensitiveSearch] == NSOrderedSame) return YES;
    }
    for (NSString *c in contains) {
        if ([text rangeOfString:c].location != NSNotFound) return YES;
    }
    return NO;
}

@interface FDScanner : NSObject
+ (UIView *)firstVisibleMatchWithContains:(NSArray<NSString *> *)contains
                                    exact:(NSArray<NSString *> *)exact
                                   maxLen:(NSInteger)maxLen;
+ (NSInteger)visibleNodeCount;
@end

@implementation FDScanner

+ (NSArray<UIWindow *> *)scannableWindows {
    NSMutableArray *windows = [NSMutableArray array];
    NSMutableSet *excluded = [NSMutableSet set];
    for (UIWindow *w in [[FDFloatingController shared] fdWindows]) [excluded addObject:w];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
            if (![excluded containsObject:w] && !w.hidden) [windows addObject:w];
        }
    }
    return windows;
}

+ (BOOL)viewIsVisible:(UIView *)v inWindow:(UIWindow *)w {
    if (v.hidden || v.alpha < 0.1 || v.userInteractionEnabled == NO) return NO;
    CGRect frameInWindow = [v convertRect:v.bounds toView:w];
    CGRect visible = CGRectIntersection(frameInWindow, w.bounds);
    return visible.size.width > 4 && visible.size.height > 4;
}

+ (UIView *)searchWithContains:(NSArray<NSString *> *)contains
                         exact:(NSArray<NSString *> *)exact
                        maxLen:(NSInteger)maxLen
                        window:(UIWindow *)w
                        budget:(NSInteger *)budget {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
    UIView *bestControl = nil;
    while (stack.count > 0 && *budget > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        (*budget)--;
        if (![v isKindOfClass:UIView.class]) continue;
        if (![self viewIsVisible:v inWindow:w]) continue;
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *l = (UILabel *)v;
            if (FDTextMatches(l.text, contains, exact, maxLen)) {
                if ([v isKindOfClass:UIControl.class]) return v;
                if (!bestControl) bestControl = v;
            }
        }
        for (UIView *sub in [v.subviews reverseObjectEnumerator]) [stack addObject:sub];
    }
    return bestControl;
}

+ (UIView *)firstVisibleMatchWithContains:(NSArray<NSString *> *)contains
                                    exact:(NSArray<NSString *> *)exact
                                   maxLen:(NSInteger)maxLen {
    NSInteger budget = 2500;
    for (UIWindow *w in [self scannableWindows]) {
        UIView *hit = [self searchWithContains:contains exact:exact maxLen:maxLen window:w budget:&budget];
        if (hit) return hit;
    }
    return nil;
}

+ (NSInteger)visibleNodeCount {
    NSInteger budget = 2500;
    NSInteger count = 0;
    for (UIWindow *w in [self scannableWindows]) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        while (stack.count > 0 && budget > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            budget--; count++;
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    return count;
}
@end

#pragma mark - 协调器：两段式状态机（找入口 → 点参与 → 冷却）

typedef NS_ENUM(NSInteger, FDStage) {
    FDStageScanning = 0,   // 找"福袋"入口
    FDStageInPanel  = 1,   // 入口已点，找"参与/领取/开"
};

@implementation FDCoordinator {
    dispatch_source_t _timer;
    NSInteger _dailyCount;
    NSDate *_day;
    NSDate *_lastTrigger;
    NSDate *_lastEntryTap;
    FDStage _stage;
    NSDate *_panelDeadline;
    NSString *_lastStatus;
    BOOL _running;
}

+ (instancetype)shared { static FDCoordinator *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

- (instancetype)init {
    if ((self = [super init])) {
        _day = [NSDate date];
        _dailyCount = 0;
        _stage = FDStageScanning;
    }
    return self;
}

- (void)setStatus:(NSString *)status {
    if ([status isEqualToString:self->_lastStatus]) return;
    self->_lastStatus = status;
    [[FDFloatingController shared] updateStatus:status];
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_running) return;
        self->_running = YES;
        self->_stage = FDStageScanning;
        [self schedulePoll];
        [self setStatus:@"运行中 · 扫描"];
        FDLog(@"state=Scanning");
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_running = NO;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        [self setStatus:@"已暂停"];
        FDLog(@"state=Disabled");
    });
}

- (void)schedulePoll {
    if (!self->_running) return;
    if (self->_timer) dispatch_source_cancel(self->_timer);
    self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf poll]; });
    dispatch_resume(self->_timer);
}

- (NSArray<NSString *> *)entryKeywords {
    NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:FDKeywordKey];
    if (raw.length == 0) raw = @"福袋";
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [list addObject:t];
    }
    return list;
}

- (void)poll {
    if (!self->_running || !FDEnabled()) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if ([[FDFloatingController shared] ownsKeyWindow]) return; // 用户正在设置面板里输入

    NSDate *now = [NSDate date];
    if ([[NSCalendar currentCalendar] compareDate:now toDate:self->_day toUnitGranularity:NSCalendarUnitDay] != NSOrderedSame) {
        self->_day = now; self->_dailyCount = 0;
    }
    NSInteger limit = (NSInteger)FDNumber(FDDailyLimitKey, 30);
    if (limit > 0 && self->_dailyCount >= limit) { [self setStatus:@"今日上限已到"]; return; }

    NSTimeInterval cooldown = FDNumber(FDCooldownKey, 20);
    if (self->_lastTrigger) {
        NSTimeInterval rest = cooldown - [now timeIntervalSinceDate:self->_lastTrigger];
        if (rest > 0) { [self setStatus:[NSString stringWithFormat:@"冷却 %.0fs", rest]]; return; }
    }

    switch (self->_stage) {
        case FDStageScanning: {
            // 软限速：入口点过之后至少等 8 秒再点，避免反复开面板
            if (self->_lastEntryTap && [now timeIntervalSinceDate:self->_lastEntryTap] < 8.0) return;
            UIView *entry = [FDScanner firstVisibleMatchWithContains:[self entryKeywords] exact:@[] maxLen:20];
            if (!entry) { [self setStatus:@"运行中 · 扫描"]; return; }
            FDLog(@"stage=Scanning entry=%@ text=%@", NSStringFromClass([entry class]),
                  ([entry isKindOfClass:UILabel.class] ? [(UILabel *)entry text] : @""));
            if ([FDTap tapView:entry]) {
                self->_lastEntryTap = [NSDate date];
                self->_stage = FDStageInPanel;
                self->_panelDeadline = [now dateByAddingTimeInterval:4.0];
                [self setStatus:@"已点入口 · 找按钮"];
                FDLog(@"state=InPanel");
            }
            break;
        }
        case FDStageInPanel: {
            // 面板按钮：包含类关键词（任意长度），外加一字"开"的精确匹配
            UIView *claim = [FDScanner firstVisibleMatchWithContains:@[@"参与", @"领取", @"抢福袋", @"立即抢"]
                                                              exact:@[@"开"]
                                                              maxLen:24];
            if (claim) {
                NSString *claimText = ([claim isKindOfClass:UILabel.class] ? [(UILabel *)claim text] : @"");
                if ([claimText hasPrefix:@"已"]) {
                    // "已参与/已领取"：本次福袋已经抢过，不再点，等冷却后重新扫描
                    self->_stage = FDStageScanning;
                    self->_lastTrigger = [NSDate date];
                    [self setStatus:@"已参与过 · 冷却中"];
                    FDLog(@"state=AlreadyJoined");
                    break;
                }
                FDLog(@"stage=InPanel claim=%@ text=%@", NSStringFromClass([claim class]), claimText ?: @"");
                if ([FDTap tapView:claim]) {
                    self->_lastTrigger = [NSDate date];
                    self->_dailyCount += 1;
                    self->_stage = FDStageScanning;
                    [self setStatus:@"已点参与 · 冷却中"];
                    FDLog(@"state=Triggering count=%ld", (long)self->_dailyCount);
                }
            } else if ([now compare:self->_panelDeadline] == NSOrderedDescending) {
                self->_stage = FDStageScanning;
                [self setStatus:@"未找到参与按钮"];
                FDLog(@"state=ScanFallback reason=claim-not-found");
            }
            break;
        }
    }
}

- (void)redPacketTapped { self->_lastTrigger = [NSDate date]; }
- (NSInteger)dailyCount { return self->_dailyCount; }
@end

#pragma mark - 悬浮窗 + 设置面板

static void FDDumpRuntimeInfo(void);

@implementation FDFloatingController {
    UIWindow *_window;
    UIButton *_button;
    UIPanGestureRecognizer *_pan;
    UIWindow *_panelWindow;
    UILabel *_statusLabel;
    UITextField *_keywordField;
    UITextField *_delayField;
    UITextField *_cooldownField;
    UITextField *_limitField;
    UIButton *_diagButton;
    BOOL _lastExternalStatus;
}
+ (instancetype)shared { static FDFloatingController *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

- (void)install { [self installWithRetry:15]; }

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
        self->_button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
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

- (NSArray<UIWindow *> *)fdWindows {
    NSMutableArray *arr = [NSMutableArray array];
    if (self->_window) [arr addObject:self->_window];
    if (self->_panelWindow) [arr addObject:self->_panelWindow];
    return arr;
}

- (BOOL)ownsKeyWindow {
    for (UIWindow *w in [self fdWindows]) {
        if (w.isKeyWindow) return YES;
    }
    return NO;
}

- (void)toggle { [self togglePanel]; }

- (void)togglePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_panelWindow) {
            [self->_panelWindow resignFirstResponder];
            [self saveFields];
            self->_panelWindow.hidden = YES;
            self->_panelWindow = nil;
            return;
        }
        [self showPanel];
    });
}

- (UIWindowScene *)activeScene {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] &&
            s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    }
    return nil;
}

- (void)showPanel {
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = CGRectMake(24, 90, 290, 470);
    w.windowLevel = UIWindowLevelAlert + 8;
    w.backgroundColor = UIColor.clearColor;
    w.hidden = NO;

    UIView *card = [[UIView alloc] initWithFrame:w.bounds];
    card.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    [w addSubview:card];

    CGFloat y = 14;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 180, 22)];
    title.text = @"福袋助手";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(226, y, 48, 22);
    [close setTitle:@"完成" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];
    y += 36;

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 258, 18)];
    st.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    st.font = [UIFont systemFontOfSize:12];
    [card addSubview:st];
    self->_statusLabel = st;
    y += 26;

    [self addSwitchRowTo:card y:&y label:@"总开关（自动抢福袋）" on:FDEnabled() action:@selector(enabledChanged:)];
    [self addSwitchRowTo:card y:&y label:@"调试日志" on:[NSUserDefaults.standardUserDefaults boolForKey:FDDebugKey] action:@selector(debugChanged:)];
    _keywordField   = [self addTextRowTo:card y:&y label:@"入口关键字" value:[NSUserDefaults.standardUserDefaults stringForKey:FDKeywordKey] ?: @"福袋"];
    _delayField     = [self addNumberRowTo:card y:&y label:@"延迟触发(分)" value:FDNumber(FDDelayKey, 0)];
    _cooldownField  = [self addNumberRowTo:card y:&y label:@"冷却时间(秒)" value:FDNumber(FDCooldownKey, 20)];
    _limitField     = [self addNumberRowTo:card y:&y label:@"每日上限(0不限)" value:FDNumber(FDDailyLimitKey, 30)];

    UIButton *diag = [UIButton buttonWithType:UIButtonTypeSystem];
    diag.frame = CGRectMake(16, y, 150, 30);
    [diag setTitle:@"生成诊断文件" forState:UIControlStateNormal];
    [diag setTitleColor:[UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [diag setTitleColor:[UIColor colorWithWhite:1 alpha:0.4] forState:UIControlStateDisabled];
    [diag addTarget:self action:@selector(generateDiagnostics:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:diag];
    self->_diagButton = diag;
    y += 34;

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 258, 44)];
    tip.text = @"开启后自动扫描直播间的福袋入口并点击；\n参与按钮由关键字\"参与/领取/开\"匹配。";
    tip.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    tip.font = [UIFont systemFontOfSize:11];
    tip.numberOfLines = 0;
    [card addSubview:tip];

    self->_panelWindow = w;
    [self refreshUI];
}

- (void)generateDiagnostics:(UIButton *)sender {
    sender.enabled = NO;
    FDDumpRuntimeInfo();
    sender.enabled = YES;
    if (self->_statusLabel) {
        self->_statusLabel.text = @"已写入 Documents/fudai_dump.txt";
    }
}

- (void)addSwitchRowTo:(UIView *)card y:(CGFloat *)y label:(NSString *)label on:(BOOL)on action:(SEL)action {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, *y + 3, 180, 30)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:14];
    [card addSubview:l];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(206, *y, 51, 31)];
    sw.on = on;
    sw.onTintColor = [UIColor colorWithRed:0.20 green:0.72 blue:0.40 alpha:1.0];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [card addSubview:sw];
    *y += 44;
}

- (UITextField *)addTextRowTo:(UIView *)card y:(CGFloat *)y label:(NSString *)label value:(NSString *)v {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, *y + 8, 110, 26)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:13];
    [card addSubview:l];
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(130, *y, 130, 32)];
    f.text = v ?: @"";
    f.textColor = UIColor.whiteColor;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    f.font = [UIFont systemFontOfSize:14];
    [f addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [card addSubview:f];
    *y += 44;
    return f;
}

- (UITextField *)addNumberRowTo:(UIView *)card y:(CGFloat *)y label:(NSString *)label value:(double)v {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, *y + 8, 110, 26)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:13];
    [card addSubview:l];
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(130, *y, 130, 32)];
    f.text = [NSString stringWithFormat:@"%g", v];
    f.textColor = UIColor.whiteColor;
    f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    f.textAlignment = NSTextAlignmentCenter;
    f.font = [UIFont systemFontOfSize:14];
    [f addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [card addSubview:f];
    *y += 44;
    return f;
}

- (void)fieldChanged:(UITextField *)f { [self saveFields]; }

- (void)saveFields {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (_keywordField.text.length)   [d setObject:_keywordField.text forKey:FDKeywordKey];
    if (_delayField.text.length)     [d setDouble:[_delayField.text doubleValue] forKey:FDDelayKey];
    if (_cooldownField.text.length)  [d setDouble:[_cooldownField.text doubleValue] forKey:FDCooldownKey];
    if (_limitField.text.length)     [d setDouble:[_limitField.text doubleValue] forKey:FDDailyLimitKey];
}

- (void)enabledChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:FDEnabledKey];
    if (sw.on) [[FDCoordinator shared] start]; else [[FDCoordinator shared] stop];
    [self refreshUI];
}

- (void)debugChanged:(UISwitch *)sw {
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:FDDebugKey];
}

- (void)refreshUI {
    BOOL on = FDEnabled();
    [_button setTitle:(on ? @"福袋 · 开" : @"福袋 · 关") forState:UIControlStateNormal];
    if (_statusLabel && !_lastExternalStatus) {
        _statusLabel.text = on
            ? [NSString stringWithFormat:@"运行中 · 今日已触发 %ld 次", (long)[[FDCoordinator shared] dailyCount]]
            : @"已暂停";
    }
}

- (void)updateStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_lastExternalStatus = YES;
        if (self->_statusLabel) self->_statusLabel.text = status;
    });
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g translationInView:self->_window];
    self->_window.center = CGPointMake(self->_window.center.x + p.x, self->_window.center.y + p.y);
    [g setTranslation:CGPointZero inView:self->_window];
}
@end

#pragma mark - 抖音观察 hooks（保留：命中说明这些类在场，仅用于日志/冷却联动）

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
    FDLog(@"observe: openRedPacketWithOrderId:completion:");
    %orig;
}
%end
%end

%group GComponentOpen3
%hook AWEIMDouyinRedPacketComponent
- (void)openRedPacketWithOrderId:(id)orderId extParams:(id)params completion:(id)completion {
    FDLog(@"observe: openRedPacketWithOrderId:extParams:completion:");
    %orig;
}
%end
%end

%group GDataFetch2
%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId completion:(id)completion {
    FDLog(@"observe: fetchRedPacketInfoWithOrderId:completion:");
    %orig;
}
%end
%end

%group GDataFetch3
%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId params:(id)params completion:(id)completion {
    FDLog(@"observe: fetchRedPacketInfoWithOrderId:params:completion:");
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
        FDLog(@"observe: AWELuckyCatBannerView visible");
    }
}
%end
%end

static BOOL gCompTapped, gCompOpen2, gCompOpen3, gDataFetch2, gDataFetch3, gLuckyCat;

static void FDDumpRuntimeInfo(void) {
    @autoreleasepool {
        NSArray *keywords = @[@"RedPacket", @"redPacket", @"LuckyBag", @"luckyBag",
                              @"HongBao", @"hongbao", @"Packet", @"Lucky", @"Bag",
                              @"Lottery", @"lottery", @"TreasureBox"];
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
        [out appendFormat:@"visibleNodes=%ld\n", (long)[FDScanner visibleNodeCount]];
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

// 无条件写启动标记：不依赖 syslog 就能确认注入成功、偏好读取值和 hook 安装情况
static void FDWriteBootMarker(void) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"boot=%@\n", [NSDate date]];
        [out appendFormat:@"bundle=%@\n", NSBundle.mainBundle.bundleIdentifier ?: @"(nil)"];
        [out appendFormat:@"enabled=%@ debug=%@\n",
            [d objectForKey:FDEnabledKey] ?: @"<unset:default-NO>",
            [d objectForKey:FDDebugKey] ?: @"<unset:default-NO>"];
        [out appendFormat:@"keywords=%@\n", [d stringForKey:FDKeywordKey] ?: @"<unset>"];
        [out appendFormat:@"hooks compTapped=%d open2=%d open3=%d fetch2=%d fetch3=%d lucky=%d\n",
            gCompTapped, gCompOpen2, gCompOpen3, gDataFetch2, gDataFetch3, gLuckyCat];
        [out appendFormat:@"classes comp=%@ dm=%@ lucky=%@\n",
            NSClassFromString(@"AWEIMDouyinRedPacketComponent") ? @"FOUND" : @"MISSING",
            NSClassFromString(@"AWEIMDouyinRedPacketDataManager") ? @"FOUND" : @"MISSING",
            NSClassFromString(@"AWELuckyCatBannerView") ? @"FOUND" : @"MISSING"];
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *file = [paths.firstObject stringByAppendingPathComponent:@"fudai_boot.txt"];
        [out writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[FuDai] boot marker -> %@", file);
    }
}

%ctor {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            FDEnabledKey: @NO,
            FDDelayKey: @0,
            FDCooldownKey: @20,
            FDDailyLimitKey: @30,
            FDDebugKey: @NO,
            FDKeywordKey: @"福袋"
        }];
        NSLog(@"[FuDai] loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier);

        FDInitHooks();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [[FDFloatingController shared] install];
            FDInitHooks();
            FDWriteBootMarker();
            if (FDEnabled()) [[FDCoordinator shared] start];
            for (int i = 1; i <= 6; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FDInitHooks();
                });
            }
            if ([NSUserDefaults.standardUserDefaults boolForKey:FDDebugKey]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    FDDumpRuntimeInfo();
                });
            }
        }];
    }
}
