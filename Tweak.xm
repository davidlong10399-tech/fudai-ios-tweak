#include <UIKit/UIKit.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/QuartzCore.h>
#include <stdarg.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 0.6.0 全自动版：对照安卓版功能重写
// 推荐页自动刷视频(看视频1~5s) + 按概率点赞/关注/主页/评论/收藏/分享
// + 扫描到带"福袋"的直播间自动进入 + 精准福袋链路(LuckyBox) + UI点抢
// + 过滤(抖币价值/房间人数) + 定时养号 + 抢完自动退出循环

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
- (BOOL)canTriggerNow;
- (void)noteLuckyBoxPanelOpened;
- (void)luckyBoxSignalOnInstance:(id)manager reason:(NSString *)reason;
- (void)noteRoomModel:(id)roomModel;
- (void)noteDiamondFromManager:(id)manager;
- (void)noteLuckySignal;
@end

#pragma mark - 配置键（对照安卓版设置项）

static NSString * const FDEnabledKey        = @"fudai.enabled";
static NSString * const FDDebugKey          = @"fudai.debug";
static NSString * const FDKeywordKey        = @"fudai.keywords";
static NSString * const FDBrowseKey         = @"fudai.browse";
static NSString * const FDWatchMinKey       = @"fudai.watchMin";
static NSString * const FDWatchMaxKey       = @"fudai.watchMax";
static NSString * const FDGapMinKey         = @"fudai.gapMin";
static NSString * const FDGapMaxKey         = @"fudai.gapMax";
static NSString * const FDPLikeKey          = @"fudai.pLike";
static NSString * const FDPFollowKey        = @"fudai.pFollow";
static NSString * const FDPProfileKey       = @"fudai.pProfile";
static NSString * const FDPCommentKey       = @"fudai.pComment";
static NSString * const FDPFavKey           = @"fudai.pFav";
static NSString * const FDPShareKey         = @"fudai.pShare";
static NSString * const FDLiveLikeMinKey    = @"fudai.liveLikeMin";
static NSString * const FDLiveLikeMaxKey    = @"fudai.liveLikeMax";
static NSString * const FDLiveActProbKey    = @"fudai.liveActProb";
static NSString * const FDMinCoinsKey       = @"fudai.minCoins";
static NSString * const FDMaxRoomKey        = @"fudai.maxRoomSize";
static NSString * const FDFilterRoomKey     = @"fudai.filterRoom";
static NSString * const FDNurtureKey        = @"fudai.nurtureMinutes";
static NSString * const FDCommentsKey       = @"fudai.comments";
static NSString * const FDDelayKey          = @"fudai.delayMinutes";
static NSString * const FDCooldownKey       = @"fudai.cooldownSeconds";
static NSString * const FDDailyLimitKey     = @"fudai.dailyLimit";

static BOOL FDEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:FDEnabledKey] == nil) [d setBool:NO forKey:FDEnabledKey];
    return [d boolForKey:FDEnabledKey];
}

static double FDNum(NSString *key, double fallback) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:key] == nil) [d setDouble:fallback forKey:key];
    return [d doubleForKey:key];
}

static NSString *FDStr(NSString *key, NSString *fallback) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return (v.length ? v : fallback);
}

static void FDLog(NSString *format, ...) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:FDDebugKey]) return;
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[FuDai] %@", message);
    // 落盘到 Documents/fudai_log.txt，便于 SSH 拉取诊断
    @try {
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [NSDateFormatter new];
            fmt.dateFormat = @"HH:mm:ss";
        });
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *file = [paths.firstObject stringByAppendingPathComponent:@"fudai_log.txt"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:file error:nil];
        if (attrs && [attrs fileSize] > 200000) [fm removeItemAtPath:file error:nil];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], message];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:file];
        if (!fh) {
            [line writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {
        // 日志失败不影响主流程
    }
}

static NSInteger FDRand(NSInteger min, NSInteger max) {
    if (max < min) max = min;
    return min + (NSInteger)(arc4random_uniform((uint32_t)(max - min + 1)));
}

#pragma mark - 点击工具

static BOOL FDInvokeGestureTargets(UIGestureRecognizer *gr) {
    BOOL fired = NO;
    @try {
        NSArray *containers = [gr valueForKey:@"_targets"];
        for (id container in containers) {
            @try {
                id target = [container valueForKey:@"_target"];
                SEL action = NULL;
                id raw = [container valueForKey:@"_action"];
                if ([raw isKindOfClass:[NSString class]]) action = NSSelectorFromString(raw);
                else if ([raw isKindOfClass:[NSValue class]]) action = (SEL)[(NSValue *)raw pointerValue];
                if (target && action) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [target performSelector:action withObject:gr];
                    #pragma clang diagnostic pop
                    fired = YES;
                }
            } @catch (NSException *e) {
                FDLog(@"tap: gesture exception %@", e);
            }
        }
    } @catch (NSException *e) {
        FDLog(@"tap: targets exception %@", e);
    }
    return fired;
}

@interface FDTap : NSObject
+ (BOOL)tapView:(UIView *)view;
@end

@implementation FDTap
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
            if ([v respondsToSelector:@selector(accessibilityActivate)]) {
                if (((BOOL (*)(id, SEL))objc_msgSend)(v, @selector(accessibilityActivate))) {
                    FDLog(@"tap: accessibilityActivate %@", NSStringFromClass([v class]));
                    return YES;
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

#pragma mark - 视图扫描（单次合并扫描 + 时间预算，防主线程卡死）

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

static UIWindow *FDKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in [(UIWindowScene *)scene windows]) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static UIViewController *FDTopVC(void) {
    UIViewController *vc = FDKeyWindow().rootViewController;
    if (!vc) return nil;
    for (int i = 0; i < 8 && vc; i++) {
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (sel) { vc = sel; continue; }
        }
        if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *last = ((UINavigationController *)vc).viewControllers.lastObject;
            if (last && last != vc) { vc = last; continue; }
        }
        break;
    }
    return vc;
}

// 一次遍历同时收集所有需要的目标；80ms 硬时限 + 1200 节点上限，超时立即中止
@interface FDScanPass : NSObject
@property (nonatomic, copy) NSArray<NSString *> *textContains;   // 福袋关键字（UILabel 文字）
@property (nonatomic, copy) NSArray<NSString *> *claimContains;  // 参与/领取类（UILabel 文字）
@property (nonatomic, copy) NSArray<NSString *> *a11yNeed;       // 需要的辅助功能按钮（accessibilityLabel）
@property (nonatomic, strong) UIView *textHit;
@property (nonatomic, strong) UIView *claimHit;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *a11yHits;
@property (nonatomic, strong) UIView *textField;
@property (nonatomic, strong) UIControl *sendButton;
@property (nonatomic, strong) UIScrollView *feedScroll;
@property (nonatomic, assign) CFAbsoluteTime deadline;
@end

@implementation FDScanPass
- (instancetype)init {
    if ((self = [super init])) {
        _a11yHits = [NSMutableDictionary dictionary];
        _deadline = CFAbsoluteTimeGetCurrent() + 0.08;
    }
    return self;
}
@end

@interface FDScanner : NSObject
+ (void)runPass:(FDScanPass *)pass;
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

+ (void)runPass:(FDScanPass *)pass {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    for (UIWindow *w in [self scannableWindows]) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        NSInteger budget = 1200;
        while (stack.count > 0 && budget > 0) {
            if (CFAbsoluteTimeGetCurrent() > pass.deadline) return;
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            budget--;
            if (![v isKindOfClass:UIView.class]) continue;
            if (v.hidden || v.alpha < 0.1) continue;
            // 可见性：同 window 直接用 frame，免坐标换算
            CGRect fw = (v.window == w) ? v.frame : [v convertRect:v.bounds toView:w];
            CGRect vis = CGRectIntersection(fw, w.bounds);
            if (vis.size.width <= 4 || vis.size.height <= 4) continue;

            if (pass.textContains && !pass.textHit && [v isKindOfClass:UILabel.class]) {
                NSString *t = ((UILabel *)v).text;
                if (FDTextMatches(t, pass.textContains, @[], 20)) pass.textHit = v;
            }
            if (pass.claimContains && !pass.claimHit && [v isKindOfClass:UILabel.class]) {
                NSString *t = ((UILabel *)v).text;
                if (FDTextMatches(t, pass.claimContains, @[@"开"], 24) && ![t hasPrefix:@"已"]) pass.claimHit = v;
            }
            // a11y 按钮：只查小尺寸节点，避免命中巨型容器
            if (pass.a11yNeed.count) {
                CGSize sz = v.bounds.size;
                if (sz.width < screen.width * 0.5 && sz.height < screen.height * 0.5) {
                    NSString *a11y = v.accessibilityLabel;
                    if (a11y.length > 0 && a11y.length <= 12) {
                        for (NSString *need in pass.a11yNeed) {
                            if (!pass.a11yHits[need] && [a11y rangeOfString:need].location != NSNotFound) {
                                pass.a11yHits[need] = v;
                                break;
                            }
                        }
                    }
                }
            }
            if (!pass.textField && ([v isKindOfClass:UITextView.class] || [v isKindOfClass:UITextField.class])) {
                pass.textField = v;
            }
            if (!pass.sendButton && [v isKindOfClass:UIControl.class]) {
                UIControl *c = (UIControl *)v;
                NSString *t = ([c isKindOfClass:UIButton.class] ? [(UIButton *)c currentTitle] : @"") ?: @"";
                NSString *a = c.accessibilityLabel ?: @"";
                if ([t rangeOfString:@"发送"].location != NSNotFound ||
                    [a rangeOfString:@"发送"].location != NSNotFound) {
                    pass.sendButton = c;
                }
            }
            if (!pass.feedScroll && [v isKindOfClass:UIScrollView.class]) {
                UIScrollView *sv = (UIScrollView *)v;
                // 必须是竖向分页容器（排除横向 tab 页容器）
                if (sv.pagingEnabled &&
                    sv.contentSize.height >= sv.bounds.size.height * 1.5 &&
                    sv.contentSize.width <= sv.bounds.size.width * 1.5 &&
                    sv.bounds.size.height > screen.height * 0.75 &&
                    sv.bounds.size.width > screen.width * 0.8) {
                    pass.feedScroll = sv;
                }
            }
            for (UIView *sub in [v.subviews reverseObjectEnumerator]) [stack addObject:sub];
        }
        if (CFAbsoluteTimeGetCurrent() > pass.deadline) return;
    }
}

+ (NSInteger)visibleNodeCount {
    NSInteger budget = 1200;
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

#pragma mark - 协调器：全自动引擎

typedef NS_ENUM(NSInteger, FDEngine) {
    FDEngineUnknown = 0,
    FDEngineFeed    = 1,   // 推荐页/关注页
    FDEngineRoom    = 2,   // 直播间
};

typedef NS_ENUM(NSInteger, FDStage) {
    FDStageScanning = 0,   // 找"福袋"入口
    FDStageInPanel  = 1,   // 入口已点，找"参与/领取/开"
};

typedef NS_ENUM(NSInteger, FDCommentStep) {
    FDCommentNone = 0,
    FDCommentOpening = 1,  // 点了评论按钮等面板
    FDCommentTyping = 2,   // 找输入框填模板
    FDCommentSending = 3,  // 找发送按钮
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
    // 引擎
    FDEngine _engine;
    NSDate *_nextBrowseAct;    // 下一次刷视频/互动时间
    NSDate *_pendingScroll;    // 互动后延迟滚动
    BOOL _engagedCurrentVideo;
    NSDate *_nextCardScan;     // 寻找福袋节奏（安卓: 5秒）
    NSDate *_lastLuckySignal;  // 最近一次福袋信号（hook）
    NSDate *_nurtureDeadline;  // 定时养号截止
    // 过滤器数据
    long long _lastDiamondCount;
    long long _roomSize;
    // 评论序列
    FDCommentStep _commentStep;
    NSDate *_commentDeadline;
    NSInteger _commentBurstLeft;
}

+ (instancetype)shared { static FDCoordinator *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

- (instancetype)init {
    if ((self = [super init])) {
        _day = [NSDate date];
        _dailyCount = 0;
        _stage = FDStageScanning;
        _engine = FDEngineUnknown;
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
        self->_engine = FDEngineUnknown;
        double nurture = FDNum(FDNurtureKey, 0);
        if (nurture > 0) self->_nurtureDeadline = [NSDate dateWithTimeIntervalSinceNow:nurture * 60];
        else self->_nurtureDeadline = nil;
        [self schedulePoll];
        [self setStatus:@"运行中"];
        FDLog(@"state=Started nurture=%.0fmin", nurture);
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
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *part in [FDStr(FDKeywordKey, @"福袋") componentsSeparatedByString:@","]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [list addObject:t];
    }
    return list;
}

- (NSArray<NSString *> *)commentTemplates {
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *part in [FDStr(FDCommentsKey, @"真好啊/值得看这个/主播我看你直播好久了/666") componentsSeparatedByString:@"/"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [list addObject:t];
    }
    return list;
}

- (void)poll {
    if (!self->_running || !FDEnabled()) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if ([[FDFloatingController shared] ownsKeyWindow]) return;

    NSDate *now = [NSDate date];
    if ([[NSCalendar currentCalendar] compareDate:now toDate:self->_day toUnitGranularity:NSCalendarUnitDay] != NSOrderedSame) {
        self->_day = now; self->_dailyCount = 0;
    }
    NSInteger limit = (NSInteger)FDNum(FDDailyLimitKey, 30);
    if (limit > 0 && self->_dailyCount >= limit) { [self setStatus:@"今日上限已到"]; return; }

    // 上下文识别（零遍历成本）
    NSString *cls = NSStringFromClass([FDTopVC() class]);
    BOOL inRoom = ([cls rangeOfString:@"Live" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL inFeed = (!inRoom && [cls rangeOfString:@"Feed" options:NSCaseInsensitiveSearch].location != NSNotFound);
    FDEngine engine = inRoom ? FDEngineRoom : (inFeed ? FDEngineFeed : FDEngineUnknown);
    static NSInteger sPollTick = 0;
    if (++sPollTick % 30 == 1) FDLog(@"poll: top=%@ engine=%ld", cls, (long)engine);

    if (engine != self->_engine) {
        FDLog(@"engine -> %@ (top=%@)", inRoom ? @"Room" : (inFeed ? @"Feed" : @"?"), cls);
        self->_engine = engine;
        self->_engagedCurrentVideo = NO;
        self->_nextBrowseAct = nil;
        if (engine == FDEngineRoom) self->_lastLuckySignal = now;
    }

    BOOL nurturing = (self->_nurtureDeadline && [now compare:self->_nurtureDeadline] == NSOrderedAscending);
    BOOL commentActive = (self->_commentStep != FDCommentNone);

    if (engine == FDEngineFeed) {
        [self feedTickAt:now nurturing:nurturing commentActive:commentActive];
    } else if (engine == FDEngineRoom) {
        [self roomTickAt:now commentActive:commentActive];
    } else if (commentActive) {
        // 评论面板打开时顶层VC是评论页，引擎显示 Unknown，仍要推进评论序列
        FDScanPass *pass = [FDScanPass new];
        [FDScanner runPass:pass];
        [self commentTickWithPass:pass now:now];
    }
}

#pragma mark 推荐页：刷视频 + 互动 + 找福袋直播间

- (void)feedTickAt:(NSDate *)now nurturing:(BOOL)nurturing commentActive:(BOOL)commentActive {
    BOOL cardDue = !nurturing && (!self->_nextCardScan || [now compare:self->_nextCardScan] == NSOrderedDescending);
    BOOL engageDue = !self->_nextBrowseAct || [now compare:self->_nextBrowseAct] == NSOrderedDescending;
    BOOL scrollDue = self->_pendingScroll && [now compare:self->_pendingScroll] != NSOrderedAscending;

    // 空闲时刻：完全不扫描，主线程零负担
    if (!cardDue && !engageDue && !scrollDue && !commentActive) {
        if (nurturing) {
            [self setStatus:[NSString stringWithFormat:@"定时养号中 · 剩 %.0f 分", [self->_nurtureDeadline timeIntervalSinceDate:now] / 60.0]];
        } else {
            [self setStatus:@"浏览推荐页"];
        }
        return;
    }

    FDScanPass *pass = [FDScanPass new];
    if (cardDue) pass.textContains = [self entryKeywords];
    if (engageDue) pass.a11yNeed = @[@"点赞", @"赞", @"关注", @"头像", @"收藏", @"分享", @"评论"];
    [FDScanner runPass:pass];

    // 找福袋直播间卡片（安卓"寻找福袋 5秒"节奏）
    if (cardDue) {
        self->_nextCardScan = [now dateByAddingTimeInterval:5.0];
        if (pass.textHit) {
            if ([FDTap tapView:pass.textHit]) {
                self->_lastLuckySignal = now;
                self->_stage = FDStageScanning;
                [self setStatus:@"发现福袋直播 · 进入"];
                FDLog(@"browse: live card tapped");
                return;
            }
        }
    }

    // 评论序列推进
    [self commentTickWithPass:pass now:now];

    // 互动 + 滚动节奏（看视频1~5s，间隔1~3s）
    if (engageDue) {
        if (!self->_engagedCurrentVideo) {
            self->_engagedCurrentVideo = YES;
            [self rollFeedEngagementWithPass:pass];
            self->_pendingScroll = [now dateByAddingTimeInterval:FDRand((NSInteger)FDNum(FDGapMinKey, 1), (NSInteger)FDNum(FDGapMaxKey, 3))];
            return;
        }
        // 互动完毕且到点 → 滚下一个
        [self scrollFeedNext];
        self->_engagedCurrentVideo = NO;
        self->_pendingScroll = nil;
        self->_nextBrowseAct = [now dateByAddingTimeInterval:FDRand((NSInteger)FDNum(FDWatchMinKey, 1), (NSInteger)FDNum(FDWatchMaxKey, 5))];
        if (!nurturing) [self setStatus:@"浏览推荐页"];
        return;
    }
    if (scrollDue) {
        [self scrollFeedNext];
        self->_pendingScroll = nil;
    }
}

- (void)rollFeedEngagementWithPass:(FDScanPass *)pass {
    NSInteger roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPLikeKey, 35)) {
        UIView *like = pass.a11yHits[@"点赞"] ?: pass.a11yHits[@"赞"];
        if (like) { [FDTap tapView:like]; FDLog(@"feed: liked"); }
    }
    roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPFollowKey, 10)) {
        UIView *follow = pass.a11yHits[@"关注"];
        if (follow) { [FDTap tapView:follow]; FDLog(@"feed: followed"); }
    }
    roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPProfileKey, 10)) {
        UIView *avatar = pass.a11yHits[@"头像"];
        if (avatar) { [FDTap tapView:avatar]; FDLog(@"feed: profile"); }
    }
    roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPFavKey, 5)) {
        UIView *fav = pass.a11yHits[@"收藏"];
        if (fav) { [FDTap tapView:fav]; FDLog(@"feed: favorited"); }
    }
    roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPShareKey, 3)) {
        UIView *share = pass.a11yHits[@"分享"];
        if (share) { [FDTap tapView:share]; FDLog(@"feed: share panel"); }
    }
    roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPCommentKey, 20)) {
        [self startCommentWithView:pass.a11yHits[@"评论"]];
    }
}

- (void)scrollFeedNext {
    UIScrollView *sv = [self feedScrollViewInTopVC];
    if (!sv) {
        FDLog(@"feed: no scroll view inside topVC %@", NSStringFromClass([FDTopVC() class]));
        return;
    }
    [self advanceFeedStep:0 sv:sv];
}

// 只在推荐页 VC 自己的视图子树里找滚动容器（TableView/CollectionView 都认），避免猜错
- (UIScrollView *)feedScrollViewInTopVC {
    UIViewController *top = FDTopVC();
    if (!top || !top.viewIfLoaded) return nil;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:top.view];
    NSInteger budget = 600;
    while (stack.count > 0 && budget > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        budget--;
        if ([v isKindOfClass:UIScrollView.class]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (!sv.hidden && sv.alpha > 0.3 &&
                sv.bounds.size.height > screen.height * 0.7 &&
                sv.bounds.size.width > screen.width * 0.7) {
                return sv;
            }
        }
        for (UIView *sub in [v.subviews reverseObjectEnumerator]) [stack addObject:sub];
    }
    return nil;
}

// 带验证的切视频：每条路径调用后 0.9s 检查 contentOffset 是否真的移动，没动自动降级
- (void)advanceFeedStep:(NSInteger)step sv:(UIScrollView *)sv {
    CGPoint before = sv.contentOffset;
    switch (step) {
        case 0: {
            // 路径1：抖音优化同款 scrollToNextVideo（连续失败3次后跳过，避免每轮浪费0.9s）
            static NSInteger s2nFails = 0;
            if (s2nFails < 3 && [self callScrollToNextVideoFrom:FDTopVC()]) {
                __block NSInteger *fails = &s2nFails;
                __weak typeof(self) ws = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (!ws) return;
                    if (fabs(sv.contentOffset.y - before.y) > 60) {
                        FDLog(@"feed: advanced via scrollToNextVideo");
                    } else {
                        (*fails)++;
                        FDLog(@"feed: scrollToNextVideo no-op (%d/3), fallback", *fails);
                        [ws advanceFeedStep:1 sv:sv];
                    }
                });
                return;
            }
            [self advanceFeedStep:1 sv:sv];
            return;
        }
        case 1: {
            // 路径2：运行时发现的 next 选择器
            UIViewController *top = FDTopVC();
            SEL nextSel = [self nextVideoSelectorForTopVC:top];
            if (nextSel) {
                @try {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [top performSelector:nextSel];
                    #pragma clang diagnostic pop
                    [self verifyAdvance:step sv:sv from:before];
                    return;
                } @catch (NSException *e) {
                    FDLog(@"feed: next-video method exception %@", e);
                }
            }
            [self advanceFeedStep:2 sv:sv];
            return;
        }
        case 2: {
            // 路径3：Table/Collection 自己的滚动 API + 手动补发滚动结束回调
            NSIndexPath *targetIp = nil;
            @try {
                if ([sv isKindOfClass:UITableView.class]) {
                    UITableView *tv = (UITableView *)sv;
                    CGFloat rh = MAX(sv.bounds.size.height, 1);
                    NSInteger page = (NSInteger)round(sv.contentOffset.y / rh);
                    NSInteger n = [tv numberOfRowsInSection:0];
                    if (page + 1 < n) targetIp = [NSIndexPath indexPathForRow:page + 1 inSection:0];
                    if (targetIp) [tv scrollToRowAtIndexPath:targetIp atScrollPosition:UITableViewScrollPositionTop animated:YES];
                } else if ([sv isKindOfClass:UICollectionView.class]) {
                    UICollectionView *cv = (UICollectionView *)sv;
                    NSInteger page = (NSInteger)round(sv.contentOffset.y / MAX(sv.bounds.size.height, 1));
                    NSInteger n = [cv numberOfItemsInSection:0];
                    if (page + 1 < n) targetIp = [NSIndexPath indexPathForItem:page + 1 inSection:0];
                    if (targetIp) [cv scrollToItemAtIndexPath:targetIp atScrollPosition:UICollectionViewScrollPositionTop animated:YES];
                }
            } @catch (NSException *e) {
                FDLog(@"feed: scrollToRow/Item exception %@", e);
            }
            if (targetIp) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self fireScrollEndFor:sv];
                });
                [self verifyAdvance:step sv:sv from:before];
                return;
            }
            FDLog(@"feed: no row/item to scroll (page+1 out of range)");
            [self advanceFeedStep:3 sv:sv];
            return;
        }
        default: {
            // 路径4：强滚 + 补发滚动结束回调
            CGPoint off = sv.contentOffset;
            off.y += sv.bounds.size.height;
            [sv setContentOffset:off animated:NO];
            [self fireScrollEndFor:sv];
            FDLog(@"feed: fallback scrolled to y=%.0f + end callback", off.y);
            return;
        }
    }
}

- (void)verifyAdvance:(NSInteger)step sv:(UIScrollView *)sv from:(CGPoint)before {
    __weak UIScrollView *wsv = sv;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *s2 = wsv;
        if (!s2 || !ws) return;
        if (fabs(s2.contentOffset.y - before.y) > 60) {
            FDLog(@"feed: advanced via step %ld (y=%.0f)", (long)step, s2.contentOffset.y);
            return;
        }
        FDLog(@"feed: step %ld no movement, trying next", (long)step);
        [ws advanceFeedStep:step + 1 sv:s2];
    });
}

// 手动补发滚动结束回调：抖音靠 scrollViewDidEndDecelerating 切换播放器（强滚黑屏的根因）
- (void)fireScrollEndFor:(UIScrollView *)sv {
    id del = sv.delegate;
    if (del && [del respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(del, @selector(scrollViewDidEndDecelerating:), sv);
        FDLog(@"feed: fired scrollViewDidEndDecelerating");
    }
}

// 抖音优化同款：从推荐页 VC 及其分页管理器上调用 scrollToNextVideo
- (BOOL)callScrollToNextVideoFrom:(UIViewController *)top {
    if (!top) return NO;
    SEL sel = NSSelectorFromString(@"scrollToNextVideo");
    NSMutableArray *candidates = [NSMutableArray arrayWithObject:top];
    for (NSString *key in @[@"pagingManager", @"detailPagingManager", @"feedPagingManager", @"viewModel", @"feedViewModel"]) {
        @try {
            id v = [top valueForKey:key];
            if (v) [candidates addObject:v];
        } @catch (NSException *e) {
            // KVC 键不存在，跳过
        }
    }
    for (id c in candidates) {
        if ([c respondsToSelector:sel]) {
            @try {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [c performSelector:sel];
                #pragma clang diagnostic pop
                FDLog(@"feed: scrollToNextVideo on %@", NSStringFromClass([c class]));
                return YES;
            } @catch (NSException *e) {
                FDLog(@"scrollToNextVideo exception %@", e);
            }
        }
    }
    return NO;
}

// 在推荐页 VC（及其父类）里找"下一个视频"方法，找到后按类名缓存
- (SEL)nextVideoSelectorForTopVC:(UIViewController *)top {
    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (!top) return NULL;
    NSString *clsName = NSStringFromClass([top class]);
    NSString *cached = cache[clsName];
    if (cached) return NSSelectorFromString(cached);

    SEL found = NULL;
    Class cls = [top class];
    for (int depth = 0; depth < 3 && cls && !found; depth++) {
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(cls, &mcount);
        for (unsigned int i = 0; i < mcount; i++) {
            SEL s = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(s);
            if (name.length > 20) continue; // 只要无参短方法
            NSString *lower = [name lowercaseString];
            if ([lower containsString:@"next"] &&
                ([lower hasPrefix:@"scroll"] || [lower hasPrefix:@"feed"] || [lower hasPrefix:@"go"] ||
                 [lower hasPrefix:@"move"] || [lower hasPrefix:@"play"] || [lower hasPrefix:@"to"] ||
                 [lower hasPrefix:@"didclick"] || [lower containsString:@"tonext"])) {
                if ([top respondsToSelector:s]) { found = s; break; }
            }
        }
        free(methods);
        cls = class_getSuperclass(cls);
    }
    if (found) {
        cache[clsName] = NSStringFromSelector(found);
        FDLog(@"feed: next-video selector found: %@", NSStringFromSelector(found));
    } else {
        FDLog(@"feed: no next-video selector on %@", clsName);
    }
    return found;
}

#pragma mark 评论序列（跨 tick 状态机）

- (void)startCommentWithView:(UIView *)btn {
    if (self->_commentStep != FDCommentNone || !btn) return;
    if ([FDTap tapView:btn]) {
        self->_commentStep = FDCommentOpening;
        self->_commentDeadline = [NSDate dateWithTimeIntervalSinceNow:6.0];
        FDLog(@"comment: panel opening");
    }
}

- (void)commentTickWithPass:(FDScanPass *)pass now:(NSDate *)now {
    if (self->_commentStep == FDCommentNone) return;
    if ([now compare:self->_commentDeadline] == NSOrderedDescending) {
        self->_commentStep = FDCommentNone;
        FDLog(@"comment: timeout");
        return;
    }
    switch (self->_commentStep) {
        case FDCommentOpening: {
            UIView *field = pass.textField;
            if ([field isKindOfClass:UITextField.class]) {
                ((UITextField *)field).text = [self commentTemplates].firstObject ?: @"真好啊";
                self->_commentStep = FDCommentSending;
                self->_commentDeadline = [now dateByAddingTimeInterval:4.0];
                FDLog(@"comment: typed (field)");
            } else if ([field isKindOfClass:UITextView.class]) {
                UITextView *tv = (UITextView *)field;
                [tv becomeFirstResponder];
                tv.text = [self commentTemplates].firstObject ?: @"真好啊";
                self->_commentStep = FDCommentSending;
                self->_commentDeadline = [now dateByAddingTimeInterval:4.0];
                FDLog(@"comment: typed (textView)");
            }
            break;
        }
        case FDCommentSending: {
            if (pass.sendButton) {
                [pass.sendButton sendActionsForControlEvents:UIControlEventTouchUpInside];
                self->_commentStep = FDCommentNone;
                FDLog(@"comment: sent");
            }
            break;
        }
        default: break;
    }
}

#pragma mark 直播间：抢福袋 + 互动 + 自动退出

- (void)roomTickAt:(NSDate *)now commentActive:(BOOL)commentActive {
    FDScanPass *pass = [FDScanPass new];
    pass.textContains = [self entryKeywords];
    pass.claimContains = @[@"参与", @"领取", @"抢福袋", @"立即抢"];
    pass.a11yNeed = @[@"点赞", @"赞", @"评论"];
    [FDScanner runPass:pass];

    // 直播间点赞：触发概率3%，一次点 2~10 次
    NSInteger roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDLiveActProbKey, 3)) {
        UIView *like = pass.a11yHits[@"点赞"] ?: pass.a11yHits[@"赞"];
        if (like) {
            NSInteger times = FDRand((NSInteger)FDNum(FDLiveLikeMinKey, 2), (NSInteger)FDNum(FDLiveLikeMaxKey, 10));
            for (NSInteger i = 0; i < times; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [FDTap tapView:like];
                });
            }
            FDLog(@"room: like burst x%ld", (long)times);
        }
    }
    // 直播间评论（概率打折，避免太频繁）
    roll = FDRand(1, 100);
    if ((double)roll <= FDNum(FDPCommentKey, 20) * 0.15) {
        [self startCommentWithView:pass.a11yHits[@"评论"]];
    }
    [self commentTickWithPass:pass now:now];

    // 抢福袋两段式
    NSTimeInterval cooldown = FDNum(FDCooldownKey, 20);
    if (self->_lastTrigger) {
        NSTimeInterval rest = cooldown - [now timeIntervalSinceDate:self->_lastTrigger];
        if (rest > 0) {
            [self setStatus:[NSString stringWithFormat:@"冷却 %.0fs", rest]];
            [self maybeLeaveRoomAt:now];
            return;
        }
    }

    switch (self->_stage) {
        case FDStageScanning: {
            if (self->_lastEntryTap && [now timeIntervalSinceDate:self->_lastEntryTap] < 8.0) {
                [self maybeLeaveRoomAt:now];
                return;
            }
            UIView *entry = pass.textHit;
            if (!entry) {
                [self setStatus:@"直播间扫描中"];
                [self maybeLeaveRoomAt:now];
                return;
            }
            FDLog(@"stage=Scanning entry=%@", NSStringFromClass([entry class]));
            if ([FDTap tapView:entry]) {
                self->_lastEntryTap = [NSDate date];
                self->_lastLuckySignal = now;
                self->_stage = FDStageInPanel;
                self->_panelDeadline = [now dateByAddingTimeInterval:4.0];
                [self setStatus:@"已点入口 · 找按钮"];
                FDLog(@"state=InPanel");
            }
            break;
        }
        case FDStageInPanel: {
            UIView *claim = pass.claimHit;
            if (claim) {
                NSString *claimText = ([claim isKindOfClass:UILabel.class] ? [(UILabel *)claim text] : @"");
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
                FDLog(@"state=ScanFallback");
            }
            break;
        }
    }
}

// 抢完/没福袋后自动退出直播间回推荐页（安卓: 抢完等待10秒→换直播间）
- (void)maybeLeaveRoomAt:(NSDate *)now {
    NSTimeInterval sinceSignal = [now timeIntervalSinceDate:self->_lastLuckySignal ?: now];
    if (sinceSignal < FDNum(FDCooldownKey, 20) + 10.0) return;
    UIViewController *top = FDTopVC();
    if (top.navigationController && top.navigationController.viewControllers.count > 1) {
        [self setStatus:@"抢完 · 退出直播间"];
        FDLog(@"room: leaving (pop)");
        [top.navigationController popViewControllerAnimated:YES];
        self->_lastLuckySignal = now; // 防连点
    }
}

#pragma mark 精准福袋链路

- (BOOL)canTriggerNow {
    if (!self->_running || !FDEnabled()) return NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    if (self->_nurtureDeadline && [NSDate date] < self->_nurtureDeadline) return NO;
    NSDate *now = [NSDate date];
    NSInteger limit = (NSInteger)FDNum(FDDailyLimitKey, 30);
    if (limit > 0 && self->_dailyCount >= limit) return NO;
    if (self->_lastTrigger && [now timeIntervalSinceDate:self->_lastTrigger] < FDNum(FDCooldownKey, 20)) return NO;
    if (self->_lastEntryTap && [now timeIntervalSinceDate:self->_lastEntryTap] < 8.0) return NO;
    return YES;
}

- (void)noteLuckyBoxPanelOpened {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_stage = FDStageInPanel;
        self->_panelDeadline = [NSDate dateWithTimeIntervalSinceNow:4.0];
        [self setStatus:@"面板已开 · 找按钮"];
        FDLog(@"state=InPanel reason=luckybox-manager");
    });
}

- (void)luckyBoxSignalOnInstance:(id)manager reason:(NSString *)reason {
    if (![self canTriggerNow]) return;
    // 过滤：普通福袋价值低于X抖币不抢
    double minCoins = FDNum(FDMinCoinsKey, 10);
    if (minCoins > 0 && self->_lastDiamondCount > 0 && self->_lastDiamondCount < (long long)minCoins) {
        [self setStatus:@"福袋价值过低 · 跳过"];
        FDLog(@"luckybox skip: coins=%lld < %.0f", self->_lastDiamondCount, minCoins);
        return;
    }
    // 过滤：只抢X人以内直播间
    if ([NSUserDefaults.standardUserDefaults boolForKey:FDFilterRoomKey] && self->_roomSize > 0) {
        double maxRoom = FDNum(FDMaxRoomKey, 1000);
        if (self->_roomSize > (long long)maxRoom) {
            [self setStatus:@"直播间人数过多 · 跳过"];
            FDLog(@"luckybox skip: room=%lld > %.0f", self->_roomSize, maxRoom);
            return;
        }
    }
    FDLog(@"luckybox signal reason=%@ manager=%@", reason, NSStringFromClass([manager class]));
    NSTimeInterval delay = FDNum(FDDelayKey, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * 60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self canTriggerNow]) return;
        SEL open = NSSelectorFromString(@"openGrabLuckyBoxView");
        if (manager && [manager respondsToSelector:open]) {
            self->_lastEntryTap = [NSDate date];
            self->_lastLuckySignal = [NSDate date];
            [self setStatus:@"发现福袋 · 开面板"];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [manager performSelector:open];
            #pragma clang diagnostic pop
            FDLog(@"state=PanelOpenCalled");
        }
    });
}

- (void)noteRoomModel:(id)roomModel {
    if (!roomModel) return;
    @try {
        for (NSString *key in @[@"userCount", @"audienceCount", @"memberCount", @"totalUserCount", @"watchCount"]) {
            id v = [roomModel valueForKey:key];
            if ([v isKindOfClass:NSNumber.class]) {
                self->_roomSize = [(NSNumber *)v longLongValue];
                FDLog(@"room size=%lld via %@", self->_roomSize, key);
                return;
            }
        }
    } @catch (NSException *e) {
        FDLog(@"roomModel read exception %@", e);
    }
}

- (void)noteDiamondFromManager:(id)manager {
    @try {
        id item = [manager valueForKey:@"shortTouchItem"];
        if (!item) return;
        id v = [item valueForKey:@"diamondCount"];
        if ([v isKindOfClass:NSNumber.class]) {
            self->_lastDiamondCount = [(NSNumber *)v longLongValue];
            FDLog(@"diamond count=%lld", self->_lastDiamondCount);
        }
    } @catch (NSException *e) {
        FDLog(@"diamond read exception %@", e);
    }
}

- (void)noteLuckySignal { self->_lastLuckySignal = [NSDate date]; }
- (void)redPacketTapped { self->_lastTrigger = [NSDate date]; }
- (NSInteger)dailyCount { return self->_dailyCount; }
@end

#pragma mark - 悬浮窗 + 设置面板（对照安卓版配置项，可滚动）

static void FDDumpRuntimeInfo(void);

@implementation FDFloatingController {
    UIWindow *_window;
    UIButton *_button;
    UIPanGestureRecognizer *_pan;
    UIWindow *_panelWindow;
    UILabel *_statusLabel;
    UIButton *_diagButton;
    BOOL _lastExternalStatus;
    NSMutableDictionary<NSString *, UITextField *> *_fields;
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
            FDLog(@"install: scene not ready, retries=%ld", (long)retries);
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
            [self saveAll];
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
    w.frame = CGRectMake(14, 70, 300, 560);
    w.windowLevel = UIWindowLevelAlert + 8;
    w.backgroundColor = UIColor.clearColor;
    w.hidden = NO;

    UIView *card = [[UIView alloc] initWithFrame:w.bounds];
    card.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    [w addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 180, 22)];
    title.text = @"福袋助手 · 全自动";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(232, 14, 52, 22);
    [close setTitle:@"完成" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, 268, 18)];
    st.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    st.font = [UIFont systemFontOfSize:12];
    [card addSubview:st];
    self->_statusLabel = st;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 64, 300, 496)];
    scroll.contentSize = CGSizeMake(300, 720);
    scroll.showsVerticalScrollIndicator = YES;
    [card addSubview:scroll];

    self->_fields = [NSMutableDictionary dictionary];
    CGFloat y = 8;
    y = [self switchRowIn:scroll y:y key:FDEnabledKey label:@"总开关（自动抢福袋）"];
    y = [self switchRowIn:scroll y:y key:FDBrowseKey label:@"自动逛推荐页+找福袋"];
    y = [self dualRowIn:scroll y:y label1:@"看视频(秒)" key1:FDWatchMinKey def1:@1 label2:@"~" key2:FDWatchMaxKey def2:@5];
    y = [self dualRowIn:scroll y:y label1:@"操作间隔(秒)" key1:FDGapMinKey def1:@1 label2:@"~" key2:FDGapMaxKey def2:@3];
    y = [self dualRowIn:scroll y:y label1:@"点赞概率%" key1:FDPLikeKey def1:@35 label2:@"关注%" key2:FDPFollowKey def2:@10];
    y = [self dualRowIn:scroll y:y label1:@"主页概率%" key1:FDPProfileKey def1:@10 label2:@"评论%" key2:FDPCommentKey def2:@20];
    y = [self dualRowIn:scroll y:y label1:@"收藏概率%" key1:FDPFavKey def1:@5 label2:@"分享%" key2:FDPShareKey def2:@3];
    y = [self dualRowIn:scroll y:y label1:@"直播间点赞次数" key1:FDLiveLikeMinKey def1:@2 label2:@"~" key2:FDLiveLikeMaxKey def2:@10];
    y = [self dualRowIn:scroll y:y label1:@"直播间触发%" key1:FDLiveActProbKey def1:@3 label2:@"定时养号(分)" key2:FDNurtureKey def2:@0];
    y = [self dualRowIn:scroll y:y label1:@"福袋低于(抖币)不抢" key1:FDMinCoinsKey def1:@10 label2:@"只抢X人内" key2:FDMaxRoomKey def2:@1000];
    y = [self switchRowIn:scroll y:y key:FDFilterRoomKey label:@"启用人数过滤"];
    y = [self dualRowIn:scroll y:y label1:@"冷却(秒)" key1:FDCooldownKey def1:@20 label2:@"每日上限" key2:FDDailyLimitKey def2:@30];
    y = [self fieldRowIn:scroll y:y key:FDKeywordKey label:@"福袋关键字" value:FDStr(FDKeywordKey, @"福袋")];
    y = [self fieldRowIn:scroll y:y key:FDCommentsKey label:@"评论模板(/分隔)" value:FDStr(FDCommentsKey, @"真好啊/值得看这个/主播我看你直播好久了/666")];
    y = [self switchRowIn:scroll y:y key:FDDebugKey label:@"调试日志"];

    UIButton *diag = [UIButton buttonWithType:UIButtonTypeSystem];
    diag.frame = CGRectMake(16, y, 150, 30);
    [diag setTitle:@"生成诊断文件" forState:UIControlStateNormal];
    [diag setTitleColor:[UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [diag addTarget:self action:@selector(generateDiagnostics:) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:diag];
    self->_diagButton = diag;
    scroll.contentSize = CGSizeMake(300, y + 50);

    self->_panelWindow = w;
    [self refreshUI];
}

- (CGFloat)switchRowIn:(UIScrollView *)scroll y:(CGFloat)y key:(NSString *)key label:(NSString *)label {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 5, 190, 26)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:13];
    l.adjustsFontSizeToFitWidth = YES;
    [scroll addSubview:l];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(216, y, 51, 31)];
    sw.on = [NSUserDefaults.standardUserDefaults boolForKey:key];
    sw.onTintColor = [UIColor colorWithRed:0.20 green:0.72 blue:0.40 alpha:1.0];
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    sw.accessibilityIdentifier = key;
    [scroll addSubview:sw];
    return y + 42;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = sw.accessibilityIdentifier;
    if (!key.length) return;
    [NSUserDefaults.standardUserDefaults setBool:sw.on forKey:key];
    if ([key isEqualToString:FDEnabledKey]) {
        if (sw.on) [[FDCoordinator shared] start]; else [[FDCoordinator shared] stop];
        [self refreshUI];
    }
}

- (CGFloat)fieldRowIn:(UIScrollView *)scroll y:(CGFloat)y key:(NSString *)key label:(NSString *)label value:(NSString *)v {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 8, 240, 20)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:l];
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(16, y + 30, 268, 32)];
    f.text = v ?: @"";
    f.textColor = UIColor.whiteColor;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    f.font = [UIFont systemFontOfSize:13];
    [f addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [scroll addSubview:f];
    self->_fields[key] = f;
    return y + 70;
}

- (CGFloat)dualRowIn:(UIScrollView *)scroll y:(CGFloat)y label1:(NSString *)l1 key1:(NSString *)k1 def1:(NSNumber *)d1 label2:(NSString *)l2 key2:(NSString *)k2 def2:(NSNumber *)d2 {
    UILabel *la = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 8, 110, 18)];
    la.text = l1;
    la.textColor = UIColor.whiteColor;
    la.font = [UIFont systemFontOfSize:11];
    [scroll addSubview:la];
    UITextField *fa = [[UITextField alloc] initWithFrame:CGRectMake(16, y + 28, 118, 30)];
    double v1 = [NSUserDefaults.standardUserDefaults objectForKey:k1] ? [NSUserDefaults.standardUserDefaults doubleForKey:k1] : d1.doubleValue;
    fa.text = [NSString stringWithFormat:@"%g", v1];
    fa.textColor = UIColor.whiteColor;
    fa.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    fa.borderStyle = UITextBorderStyleRoundedRect;
    fa.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    fa.textAlignment = NSTextAlignmentCenter;
    fa.font = [UIFont systemFontOfSize:13];
    [fa addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [scroll addSubview:fa];
    self->_fields[k1] = fa;

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(152, y + 8, 110, 18)];
    lb.text = l2;
    lb.textColor = UIColor.whiteColor;
    lb.font = [UIFont systemFontOfSize:11];
    [scroll addSubview:lb];
    UITextField *fb = [[UITextField alloc] initWithFrame:CGRectMake(152, y + 28, 118, 30)];
    double v2 = [NSUserDefaults.standardUserDefaults objectForKey:k2] ? [NSUserDefaults.standardUserDefaults doubleForKey:k2] : d2.doubleValue;
    fb.text = [NSString stringWithFormat:@"%g", v2];
    fb.textColor = UIColor.whiteColor;
    fb.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    fb.borderStyle = UITextBorderStyleRoundedRect;
    fb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    fb.textAlignment = NSTextAlignmentCenter;
    fb.font = [UIFont systemFontOfSize:13];
    [fb addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [scroll addSubview:fb];
    self->_fields[k2] = fb;
    return y + 66;
}

- (void)fieldChanged:(UITextField *)f { [self saveAll]; }

- (void)saveAll {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *key in self->_fields) {
        UITextField *f = self->_fields[key];
        if (!f.text.length) continue;
        if ([key isEqualToString:FDKeywordKey] || [key isEqualToString:FDCommentsKey]) {
            [d setObject:f.text forKey:key];
        } else {
            [d setDouble:[f.text doubleValue] forKey:key];
        }
    }
    // 养号倒计时重置
    double nurture = [d doubleForKey:FDNurtureKey];
    if (nurture > 0 && FDEnabled()) {
        // 由协调器在 start 时应用；此处仅提示
    }
}

- (void)generateDiagnostics:(UIButton *)sender {
    sender.enabled = NO;
    FDDumpRuntimeInfo();
    sender.enabled = YES;
    if (self->_statusLabel) {
        self->_statusLabel.text = @"已写入 Documents/fudai_dump.txt";
    }
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

#pragma mark - 抖音 hooks（福袋精准链路 + 观察者）

%group GComponentTapped
%hook AWEIMDouyinRedPacketComponent
- (void)redPacketDidTapped {
    [[FDCoordinator shared] redPacketTapped];
    %orig;
}
%end
%end

%group GDataFetch2
%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId completion:(id)completion {
    FDLog(@"observe: fetchRedPacketInfo");
    %orig;
}
%end
%end

%group GDataFetch3
%hook AWEIMDouyinRedPacketDataManager
- (void)fetchRedPacketInfoWithOrderId:(id)orderId params:(id)params completion:(id)completion {
    FDLog(@"observe: fetchRedPacketInfo");
    %orig;
}
%end
%end

// 直播福袋核心（类名来自 fudai_dump.txt 实测）
%group GLuckyBoxManager
%hook IESLiveLuckyBoxServiceManager
- (void)messageReceived:(id)message {
    %orig;
    [[FDCoordinator shared] noteLuckySignal];
    [[FDCoordinator shared] luckyBoxSignalOnInstance:self reason:@"messageReceived"];
}
- (void)createLuckyBoxShortTouchItem:(id)item aniViewData:(id)aniViewData isShowEntranceAnimation:(BOOL)animate {
    %orig;
    [[FDCoordinator shared] noteLuckySignal];
    [[FDCoordinator shared] luckyBoxSignalOnInstance:self reason:@"entranceCreated"];
}
- (void)openGrabLuckyBoxView {
    %orig;
    [[FDCoordinator shared] noteLuckyBoxPanelOpened];
}
- (void)setRoomModel:(id)roomModel {
    %orig;
    [[FDCoordinator shared] noteRoomModel:roomModel];
}
- (void)updateDiamondCountForTempState:(id)state {
    %orig;
    [[FDCoordinator shared] noteDiamondFromManager:self];
}
%end
%end

static BOOL gCompTapped, gDataFetch2, gDataFetch3, gLuckyBox;

static void FDDumpRuntimeInfo(void) {
    @autoreleasepool {
        NSArray *keywords = @[@"RedPacket", @"redPacket", @"LuckyBag", @"luckyBag",
                              @"HongBao", @"hongbao", @"Packet", @"Lucky", @"Bag",
                              @"Lottery", @"lottery", @"TreasureBox",
                              @"LuckyBox", @"luckyBox", @"Rush", @"rush", @"FuDai", @"fudai"];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"totalClasses=%u\n", count];
        [out appendFormat:@"targetClass IESLiveLuckyBoxServiceManager = %@\n",
            NSClassFromString(@"IESLiveLuckyBoxServiceManager") ? @"FOUND" : @"MISSING"];
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

static void FDWriteBootMarker(void) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"boot=%@\n", [NSDate date]];
        [out appendFormat:@"bundle=%@\n", NSBundle.mainBundle.bundleIdentifier ?: @"(nil)"];
        [out appendFormat:@"enabled=%@ debug=%@ browse=%@\n",
            [d objectForKey:FDEnabledKey] ?: @"<unset>",
            [d objectForKey:FDDebugKey] ?: @"<unset>",
            [d objectForKey:FDBrowseKey] ?: @"<unset>"];
        [out appendFormat:@"keywords=%@ comments=%@\n",
            [d stringForKey:FDKeywordKey] ?: @"<unset>",
            [d stringForKey:FDCommentsKey] ?: @"<unset>"];
        [out appendFormat:@"hooks compTapped=%d fetch2=%d fetch3=%d luckyBox=%d\n",
            gCompTapped, gDataFetch2, gDataFetch3, gLuckyBox];
        [out appendFormat:@"classes luckyBoxMgr=%@\n",
            NSClassFromString(@"IESLiveLuckyBoxServiceManager") ? @"FOUND" : @"MISSING"];
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *file = [paths.firstObject stringByAppendingPathComponent:@"fudai_boot.txt"];
        [out writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[FuDai] boot marker -> %@", file);
    }
}

static void FDInitHooks(void) {
    Class comp = NSClassFromString(@"AWEIMDouyinRedPacketComponent");
    if (!gCompTapped && comp && [comp instancesRespondToSelector:@selector(redPacketDidTapped)]) {
        gCompTapped = YES; %init(GComponentTapped);
        FDLog(@"hooked redPacketDidTapped");
    }
    Class dm = NSClassFromString(@"AWEIMDouyinRedPacketDataManager");
    if (!gDataFetch2 && dm && [dm instancesRespondToSelector:@selector(fetchRedPacketInfoWithOrderId:completion:)]) {
        gDataFetch2 = YES; %init(GDataFetch2);
    }
    if (!gDataFetch3 && dm && [dm instancesRespondToSelector:@selector(fetchRedPacketInfoWithOrderId:params:completion:)]) {
        gDataFetch3 = YES; %init(GDataFetch3);
    }
    Class lbm = NSClassFromString(@"IESLiveLuckyBoxServiceManager");
    if (!gLuckyBox && lbm && [lbm instancesRespondToSelector:@selector(messageReceived:)]) {
        gLuckyBox = YES; %init(GLuckyBoxManager);
        FDLog(@"hooked IESLiveLuckyBoxServiceManager");
    }
}

%ctor {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            FDEnabledKey: @NO,
            FDDebugKey: @NO,
            FDKeywordKey: @"福袋",
            FDBrowseKey: @YES,
            FDWatchMinKey: @1,
            FDWatchMaxKey: @5,
            FDGapMinKey: @1,
            FDGapMaxKey: @3,
            FDPLikeKey: @35,
            FDPFollowKey: @10,
            FDPProfileKey: @10,
            FDPCommentKey: @20,
            FDPFavKey: @5,
            FDPShareKey: @3,
            FDLiveLikeMinKey: @2,
            FDLiveLikeMaxKey: @10,
            FDLiveActProbKey: @3,
            FDMinCoinsKey: @10,
            FDMaxRoomKey: @1000,
            FDFilterRoomKey: @NO,
            FDNurtureKey: @0,
            FDCommentsKey: @"真好啊/值得看这个/主播我看你直播好久了/666",
            FDDelayKey: @0,
            FDCooldownKey: @20,
            FDDailyLimitKey: @30
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
