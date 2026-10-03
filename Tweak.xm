#include <UIKit/UIKit.h>
#include <Foundation/Foundation.h>
#include <QuartzCore/QuartzCore.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// 0.7.0 全自动引擎——基于两份深度逆向的完全重写
//   刷视频(Browse)：抖音优化 28.52 同款 5 门卫 hook，让抖音原生自动连播接管
//                   （docs/sjj-2852-analysis.md §4，照抄最小清单）
//   抢福袋(Grab)：安卓福袋助手 DyAct 链路照抄
//                   （docs/android-fudai-analysis.md §4.5-4.9）
//   三段定时状态机：Grab(60min)→Browse(10min)→Rest(0)→循环；养号=永远 Browse
// ============================================================================

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
- (void)noteLuckySignalOnInstance:(id)manager;
- (void)noteRoomModel:(id)roomModel;
- (void)noteDiamondFromManager:(id)manager;
@end

#pragma mark - 配置（对齐安卓 MyConfig 语义）

static NSString * const FDEnabledKey      = @"fudai.enabled";
static NSString * const FDDebugKey        = @"fudai.debug";
static NSString * const FDAutoplayKey     = @"fudai.autoplay";
static NSString * const FDModeKey         = @"fudai.mode";            // 0超级 1抖币 2关注 3养号 4手动 5钻石+超级
static NSString * const FDGrabMinKey      = @"fudai.grabMinutes";     // 抢福袋时长(分)
static NSString * const FDBrowseMinKey    = @"fudai.browseMinutes";   // 刷视频时长(分)
static NSString * const FDRestMinKey      = @"fudai.restMinutes";     // 休息时长(分)
static NSString * const FDDiaAttendKey    = @"fudai.diamondAttendLimit";
static NSString * const FDDiaRewardKey    = @"fudai.diamondRewardLimit";
static NSString * const FDDiaLimitMinKey  = @"fudai.diamondLimitMin";
static NSString * const FDSupAttendKey    = @"fudai.supperAttendLimit";
static NSString * const FDSupLimitMinKey  = @"fudai.supperLimitMin";
static NSString * const FDMinSuperKey     = @"fudai.minSuperYuan";
static NSString * const FDMaxSuperKey     = @"fudai.maxSuperYuan";
static NSString * const FDMaxRoomKey      = @"fudai.maxRoomSize";
static NSString * const FDFilterRoomKey   = @"fudai.filterRoom";
static NSString * const FDWaitRoomKey     = @"fudai.waitNextRoomSec";
static NSString * const FDMaxSwitchKey    = @"fudai.maxRoomSwitch";
static NSString * const FDLikeRateKey     = @"fudai.liveLikeRate";
static NSString * const FDLikeMinKey      = @"fudai.liveLikeMin";
static NSString * const FDLikeMaxKey      = @"fudai.liveLikeMax";
static NSString * const FDCmtRateKey      = @"fudai.liveCommentRate";
static NSString * const FDCommentsKey     = @"fudai.comments";
static NSString * const FDSearchKey       = @"fudai.searchKey";
static NSString * const FDAttendModeKey   = @"fudai.attendMode";      // 6=立马
static NSString * const FDWatchSecKey     = @"fudai.watchSeconds";    // 每条视频秒数
static NSString * const FDLiveSchemeKey   = @"fudai.liveScheme";      // 直播深链
static NSString * const FDFansTeamKey     = @"fudai.fansTeam";
static NSString * const FDFansYuanKey     = @"fudai.fansTeamYuan";

static NSString * const FDPhaseKey        = @"fudai.phase";           // 0Grab 1Browse 2Rest
static NSString * const FDPhaseDlKey      = @"fudai.phaseDeadline";   // 翻转时刻(timeIntervalSince1970)
// 每日计数器（date 变更清零）
static NSString * const FDCounterDateKey  = @"fudai.counterDate";
static NSString * const FDDiaAttendNKey   = @"fudai.diaAttendN";
static NSString * const FDDiaRewardNKey   = @"fudai.diaRewardN";
static NSString * const FDSupAttendNKey   = @"fudai.supAttendN";
static NSString * const FDSupRewardNKey   = @"fudai.supRewardN";
static NSString * const FDAttentionNKey   = @"fudai.attentionN";

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

static BOOL FDBool(NSString *key, BOOL fallback) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:key] == nil) [d setBool:fallback forKey:key];
    return [d boolForKey:key];
}

static void FDLog(NSString *format, ...) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:FDDebugKey]) return;
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[FuDai] %@", message);
    @try {
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss"; });
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *file = [paths.firstObject stringByAppendingPathComponent:@"fudai_log.txt"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:file error:nil];
        if (attrs && [attrs fileSize] > 200000) [fm removeItemAtPath:file error:nil];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], message];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:file];
        if (!fh) { [line writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) { }
}

static NSInteger FDRand(NSInteger min, NSInteger max) {
    if (max < min) max = min;
    return min + (NSInteger)(arc4random_uniform((uint32_t)(max - min + 1)));
}

static void FDNumIncrement(NSString *key);

// 自动连播生效条件（门卫 hook 读取）：总开 && Browse 阶段 && 自动播放开
static volatile NSInteger gFDPhase = 0; // 0Grab 1Browse 2Rest（与 poll 同步，hook 直读）
static BOOL FDAutoPlayActive(void) {
    return FDEnabled() &&
           FDBool(FDAutoplayKey, YES) &&
           gFDPhase == 1 &&
           UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
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
            } @catch (NSException *e) { }
        }
    } @catch (NSException *e) { }
    return fired;
}

@interface FDTap : NSObject
+ (BOOL)tapView:(UIView *)view;
@end

// CollectionView 项兜底：tab 项/广场卡片这类"由 collectionView didSelect 驱动"的视图
// （程序化 selectItemAtIndexPath 不会触发 delegate，需手动补发 didSelect 回调）
static BOOL FDTapViaCollectionView(UIView *view) {
    UIView *v = view;
    UICollectionViewCell *cell = nil;
    UICollectionView *cv = nil;
    for (int i = 0; i < 8 && v; i++) {
        if (!cell && [v isKindOfClass:UICollectionViewCell.class]) cell = (UICollectionViewCell *)v;
        if ([v isKindOfClass:UICollectionView.class]) { cv = (UICollectionView *)v; break; }
        v = v.superview;
    }
    if (!cell || !cv) return NO;
    @try {
        NSIndexPath *ip = [cv indexPathForCell:cell];
        if (!ip) return NO;
        // 精简 SDK 头未声明该选择器，走 msgSend
        ((void (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(
            cv, @selector(selectItemAtIndexPath:atScrollPosition:animated:),
            ip, UICollectionViewScrollPositionCenteredVertically | UICollectionViewScrollPositionCenteredHorizontally, YES);
        id del = cv.delegate;
        if (del && [del respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(del, @selector(collectionView:didSelectItemAtIndexPath:), cv, ip);
            FDLog(@"tap: collectionView didSelect %@ item=%ld", NSStringFromClass([cv class]), (long)ip.item);
            return YES;
        }
        return NO;
    } @catch (NSException *e) {
        FDLog(@"tap: collectionView exception %@", e);
        return NO;
    }
}

// 运行时动作搜索：自定义视图（如 tab 项）常带私有 tap/click 方法，全部常规途径失败后尝试
// 祖先选择器兜底：父视图类里的单参 select/switch 方法（如 selectTabItem:），传入该项调用
static BOOL FDTapViaAncestorSelector(UIView *view) {
    UIView *v = view;
    for (int level = 0; level < 6 && v; level++) {
        @try {
            Class cls = [v class];
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(cls, &mcount);
            for (unsigned int i = 0; i < mcount; i++) {
                SEL s = method_getName(methods[i]);
                NSString *name = NSStringFromSelector(s);
                if (name.length > 28) continue;
                NSString *lower = [name lowercaseString];
                if (([lower containsString:@"select"] || [lower containsString:@"switchtab"] ||
                     [lower containsString:@"ontapitem"] || [lower containsString:@"tabitem"]) &&
                    ![lower hasPrefix:@"set"] && ![lower containsString:@"didselect"] &&
                    ![lower containsString:@"willselect"] && ![lower containsString:@"gesture"] &&
                    ![lower containsString:@"progress"] && ![lower containsString:@"shadow"] &&
                    ![lower containsString:@"update"] && ![lower containsString:@"path"]) {
                    NSMethodSignature *sig = [v methodSignatureForSelector:s];
                    if (sig && sig.numberOfArguments == 3) { // 1 个对象参数
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [v performSelector:s withObject:view];
                        #pragma clang diagnostic pop
                        FDLog(@"tap: ancestor selector %@ on %@", name, NSStringFromClass(cls));
                        return YES;
                    }
                }
            }
            free(methods);
        } @catch (NSException *e) { }
        v = v.superview;
    }
    return NO;
}

// 分段控件兜底：抖音顶部 tab 栏是 MultiTabSegmentedControl 系，按标题选中"直播"段
static BOOL FDTapViaSegmentedControl(UIView *view) {
    UIView *v = view;
    for (int i = 0; i < 8 && v; i++) {
        if ([v isKindOfClass:UISegmentedControl.class]) {
            UISegmentedControl *seg = (UISegmentedControl *)v;
            for (NSInteger sIdx = 0; sIdx < (NSInteger)seg.numberOfSegments; sIdx++) {
                NSString *t = [seg titleForSegmentAtIndex:sIdx] ?: @"";
                if ([t isEqualToString:@"直播"]) {
                    [seg setSelectedSegmentIndex:sIdx];
                    [seg sendActionsForControlEvents:UIControlEventValueChanged];
                    FDLog(@"tap: segmented index %ld (直播)", (long)sIdx);
                    return YES;
                }
            }
        }
        v = v.superview;
    }
    return NO;
}

static BOOL FDTapViaRuntimeAction(UIView *view) {
    @try {
        Class cls = [view class];
        for (int depth = 0; depth < 2 && cls; depth++) {
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(cls, &mcount);
            for (unsigned int i = 0; i < mcount; i++) {
                SEL s = method_getName(methods[i]);
                NSString *name = NSStringFromSelector(s);
                if (name.length > 24) continue;
                NSString *lower = [name lowercaseString];
                BOOL looksAction = ([lower hasPrefix:@"tap"] || [lower hasPrefix:@"click"] ||
                                    [lower hasPrefix:@"ontap"] || [lower containsString:@"tapped"] ||
                                    [lower containsString:@"clicked"] || [lower containsString:@"touchup"]);
                if (looksAction &&
                    ![lower containsString:@"gesture"] && ![lower hasPrefix:@"set"] &&
                    ![lower containsString:@"cancel"] && ![lower containsString:@"did"] &&
                    ![lower containsString:@"block"] && ![lower containsString:@"will"]) {
                    NSMethodSignature *sig = [view methodSignatureForSelector:s];
                    if (sig && sig.numberOfArguments == 2) { // 无参方法
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [view performSelector:s];
                        #pragma clang diagnostic pop
                        FDLog(@"tap: runtime action %@ on %@", name, NSStringFromClass(cls));
                        return YES;
                    }
                }
            }
            free(methods);
            cls = class_getSuperclass(cls);
        }
    } @catch (NSException *e) { }
    return NO;
}

@implementation FDTap
+ (BOOL)tapView:(UIView *)view {
    UIView *v = view;
    for (int level = 0; level < 6 && v; level++) {
        @try {
            if ([v isKindOfClass:UIControl.class]) {
                UIControl *c = (UIControl *)v;
                if (c.enabled && c.userInteractionEnabled && !c.hidden && c.alpha > 0.1) {
                    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                    FDLog(@"tap: UIControl %@ L%d", NSStringFromClass([c class]), level);
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
                    FDLog(@"tap: a11yActivate %@", NSStringFromClass([v class]));
                    return YES;
                }
            }
        } @catch (NSException *e) { }
        v = v.superview;
    }
    if (FDTapViaCollectionView(view)) return YES;
    if (FDTapViaSegmentedControl(view)) return YES;
    if (FDTapViaAncestorSelector(view)) return YES;
    if (FDTapViaRuntimeAction(view)) return YES;
    FDLog(@"tap: no target %@", NSStringFromClass([view class]));
    return NO;
}
@end

#pragma mark - 页面判定 + 扫描（单次合并 pass + 80ms 时限）

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

// 页面判据（对齐安卓 getWndState，a11y 文本）
static NSArray<NSString *> *FDPageMarkers(void) {
    return @[@"在线观众", @"本场点赞", @"点赞，喜欢", @"点击进入直播间", @"我的钱包", @"抖音号："];
}

typedef NS_ENUM(NSInteger, FDPage) {
    FDPageUnknown = 0, FDPageLive = 1, FDPageVideo = 2, FDPagePlaza = 3,
    FDPageMenu = 4, FDPageUser = 5,
};

@interface FDScanPass : NSObject
@property (nonatomic, copy) NSArray<NSString *> *bagContains;   // 福袋挂件（限左上区域）
@property (nonatomic, copy) NSArray<NSString *> *claimContains; // 面板按钮（参与类）
@property (nonatomic, copy) NSArray<NSString *> *giveupContains;// 面板放弃条件
@property (nonatomic, strong) UIView *giveupHit;
@property (nonatomic, copy) NSArray<NSString *> *cleanupContains; // 弹窗按钮
@property (nonatomic, copy) NSArray<NSString *> *a11yNeed;
@property (nonatomic, strong) UIView *bagHit;
@property (nonatomic, strong) UIView *claimHit;
@property (nonatomic, strong) UIView *cleanupHit;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *a11yHits;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *markerTexts; // marker → 完整文本
@property (nonatomic, strong) NSMutableArray<NSString *> *panelTexts; // 面板数字/金额/倒计时文本
@property (nonatomic, strong) UIView *textField;   // 评论输入框（发现即记录）
@property (nonatomic, strong) UIControl *sendButton; // 发送按钮
@property (nonatomic, assign) FDPage page;
@property (nonatomic, assign) CFAbsoluteTime deadline;
@end

@implementation FDScanPass
- (instancetype)init {
    if ((self = [super init])) {
        _a11yHits = [NSMutableDictionary dictionary];
        _markerTexts = [NSMutableDictionary dictionary];
        _panelTexts = [NSMutableArray array];
        _page = FDPageUnknown;
        _deadline = CFAbsoluteTimeGetCurrent() + 0.08;
    }
    return self;
}
@end

static BOOL FDTextContains(NSString *text, NSArray<NSString *> *keys, NSInteger maxLen) {
    if (![text isKindOfClass:NSString.class] || text.length == 0 || (NSInteger)text.length > maxLen) return NO;
    for (NSString *k in keys) {
        if ([text rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

static void FDNoteMarker(FDScanPass *pass, NSString *marker, NSString *full) {
    if (!pass.markerTexts[marker]) pass.markerTexts[marker] = full;
    if ([marker isEqualToString:@"在线观众"] || [marker isEqualToString:@"本场点赞"]) {
        if (pass.page == FDPageUnknown) pass.page = FDPageLive;
    } else if ([marker isEqualToString:@"点赞，喜欢"]) {
        if (pass.page == FDPageUnknown) pass.page = FDPageVideo;
    } else if ([marker isEqualToString:@"点击进入直播间"]) {
        pass.page = FDPagePlaza; // 广场判据最明确
    } else if ([marker isEqualToString:@"我的钱包"]) {
        if (pass.page == FDPageUnknown) pass.page = FDPageMenu;
    } else if ([marker isEqualToString:@"抖音号："]) {
        if (pass.page == FDPageUnknown) pass.page = FDPageUser;
    }
}

// 解析 X分X秒 → 秒
static NSInteger FDParseSeconds(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return 0;
    NSRange m = [text rangeOfString:@"分"];
    NSRange s = [text rangeOfString:@"秒"];
    if (m.location == NSNotFound || s.location == NSNotFound || s.location < m.location) return 0;
    NSString *mStr = [text substringWithRange:NSMakeRange(0, m.location)];
    NSString *sStr = [text substringWithRange:NSMakeRange(m.location + 1, s.location - m.location - 1)];
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    mStr = [[mStr componentsSeparatedByCharactersInSet:nonDigit] componentsJoinedByString:@""];
    sStr = [[sStr componentsSeparatedByCharactersInSet:nonDigit] componentsJoinedByString:@""];
    if (mStr.length == 0 && sStr.length == 0) return 0;
    NSInteger mm = mStr.length ? mStr.integerValue : 0;
    NSInteger ss = sStr.length ? sStr.integerValue : 0;
    return mm * 60 + ss;
}

@interface FDScanner : NSObject
+ (void)runPass:(FDScanPass *)pass;
+ (UIScrollView *)fullPageVerticalScrollInTopVC;
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
    // 福袋挂件区：左上角（对齐安卓 left<600,top<550 的比例版）
    CGFloat regionW = screen.width * 0.5;
    CGFloat regionH = screen.height * 0.35;
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
            CGRect fw = (v.window == w) ? v.frame : [v convertRect:v.bounds toView:w];
            CGRect vis = CGRectIntersection(fw, w.bounds);
            if (vis.size.width <= 4 || vis.size.height <= 4) continue;

            // 页面判据（text 与 a11y 都查；a11y 为 nil 时禁止匹配——nil 消息返回 0 会被误判命中）
            NSString *a11y = v.accessibilityLabel;
            for (NSString *marker in FDPageMarkers()) {
                if (pass.markerTexts[marker]) continue;
                if (a11y.length > 0 && [a11y rangeOfString:marker].location != NSNotFound) { FDNoteMarker(pass, marker, a11y); continue; }
                if ([v isKindOfClass:UILabel.class]) {
                    NSString *t = ((UILabel *)v).text;
                    if (t.length > 0 && [t rangeOfString:marker].location != NSNotFound) FDNoteMarker(pass, marker, t);
                }
            }

            // 福袋挂件：UILabel 文字，限左上区域
            if (pass.bagContains && !pass.bagHit && [v isKindOfClass:UILabel.class]) {
                NSString *t = ((UILabel *)v).text;
                if (FDTextContains(t, pass.bagContains, 20) && fw.origin.x < regionW && fw.origin.y < regionH) {
                    pass.bagHit = v;
                }
            }
            // 面板按钮/放弃条件/弹窗（文字或 a11y，不限区域但限长度）
            if (!pass.claimHit && pass.claimContains && FDTextContains(a11y, pass.claimContains, 24)) {
                pass.claimHit = v;
            } else if (!pass.claimHit && pass.claimContains && [v isKindOfClass:UILabel.class]) {
                NSString *t = ((UILabel *)v).text;
                if (FDTextContains(t, pass.claimContains, 24)) pass.claimHit = v;
            }
            if (!pass.giveupHit && pass.giveupContains) {
                if (FDTextContains(a11y, pass.giveupContains, 24)) pass.giveupHit = v;
                else if ([v isKindOfClass:UILabel.class] && FDTextContains(((UILabel *)v).text, pass.giveupContains, 24)) pass.giveupHit = v;
            }
            if (!pass.cleanupHit && pass.cleanupContains) {
                if (FDTextContains(a11y, pass.cleanupContains, 12)) pass.cleanupHit = v;
                else if ([v isKindOfClass:UILabel.class] && FDTextContains(((UILabel *)v).text, pass.cleanupContains, 12)) pass.cleanupHit = v;
            }
            // 面板数字文本（倒计时/人数/金额/开奖）
            if ([v isKindOfClass:UILabel.class]) {
                NSString *t = ((UILabel *)v).text;
                if (t.length > 0 && t.length < 50 && pass.panelTexts.count < 24) {
                    if ([t rangeOfString:@"参考价值"].location != NSNotFound ||
                        [t rangeOfString:@"人已参加"].location != NSNotFound ||
                        [t rangeOfString:@"后开奖"].location != NSNotFound ||
                        FDParseSeconds(t) > 0 ||
                        [t rangeOfString:@"¥"].location != NSNotFound) {
                        [pass.panelTexts addObject:t];
                    }
                }
            }
            // a11y 按钮
            if (pass.a11yNeed.count) {
                CGSize sz = v.bounds.size;
                if (sz.width < screen.width * 0.5 && sz.height < screen.height * 0.5 && a11y.length > 0 && a11y.length <= 12) {
                    for (NSString *need in pass.a11yNeed) {
                        if (!pass.a11yHits[need] && [a11y rangeOfString:need].location != NSNotFound) {
                            pass.a11yHits[need] = v;
                            break;
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
                NSString *a2 = c.accessibilityLabel ?: @"";
                if ([t rangeOfString:@"发送"].location != NSNotFound ||
                    [a2 rangeOfString:@"发送"].location != NSNotFound) {
                    pass.sendButton = c;
                }
            }
            for (UIView *sub in [v.subviews reverseObjectEnumerator]) [stack addObject:sub];
        }
        if (CFAbsoluteTimeGetCurrent() > pass.deadline) return;
    }
}

+ (UIScrollView *)fullPageVerticalScrollInTopVC {
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

#pragma mark - 协调器

typedef NS_ENUM(NSInteger, FDPhase) { FDPhaseGrab = 0, FDPhaseBrowse = 1, FDPhaseRest = 2 };
typedef NS_ENUM(NSInteger, FDRoomStage) {
    FDRoomScan = 0,      // 扫福袋挂件
    FDRoomPanel = 1,     // 面板已开（抢/挂机）
    FDRoomSwitchWait = 2,// 等待换房
};

@implementation FDCoordinator {
    dispatch_source_t _timer;
    NSString *_lastStatus;
    BOOL _running;
    // 房间状态
    FDRoomStage _roomStage;
    NSDate *_panelDeadline;      // 面板超时（普通10min/超级15min）
    NSDate *_joinedDeadline;     // 挂机到开奖
    NSDate *_claimedAt;          // 参与点击防重
    NSString *_lastAnchorHint;   // 卡死检测（用状态文本近似）
    NSInteger _noBagTicks;       // 连续无福袋 tick
    NSInteger _roomSwitches;     // 换房计数（60 上限）
    NSDate *_nextRoomSwitch;     // 换房冷却
    NSDate *_nextEnterTry;       // 进房重试冷却
    NSDate *_nextFeedAdvance;    // 刷视频期：下一条视频时间
    NSDate *_lastLuckySignal;    // LuckyBox hook 信号
    BOOL _likedThisRoom;         // 本房已点赞
    BOOL _commentedThisRoom;     // 本房已评论
    BOOL _superLikeDone;         // 超级福袋挂机点赞已做
    NSString *_panelJoinedMarker;// 已参与标记
    long long _lastDiamond;
    long long _roomSize;
    NSInteger _unknownTicks;
    NSInteger _bagType;          // 0普通 2超级（本次面板）
}

+ (instancetype)shared { static FDCoordinator *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }

- (NSString *)statusText { return _lastStatus ?: @""; }
- (NSInteger)dailyCount { return (NSInteger)(FDNum(FDDiaAttendNKey, 0) + FDNum(FDSupAttendNKey, 0)); }

- (void)setStatus:(NSString *)status {
    if ([status isEqualToString:self->_lastStatus]) return;
    self->_lastStatus = status;
    [[FDFloatingController shared] updateStatus:status];
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_running) return;
        self->_running = YES;
        [self resetDailyCountersIfNeeded];
        [self loadOrInitPhase];
        [self schedulePoll];
        [self setStatus:@"运行中"];
        FDLog(@"started phase=%ld", (long)gFDPhase);
    });
}

- (void)stop {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_running = NO;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        [self setStatus:@"已暂停"];
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

- (void)resetDailyCountersIfNeeded {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd";
    NSString *today = [fmt stringFromDate:[NSDate date]];
    NSString *stored = [d stringForKey:FDCounterDateKey];
    if (![today isEqualToString:stored]) {
        [d setObject:today forKey:FDCounterDateKey];
        [d setDouble:0 forKey:FDDiaAttendNKey];
        [d setDouble:0 forKey:FDDiaRewardNKey];
        [d setDouble:0 forKey:FDSupAttendNKey];
        [d setDouble:0 forKey:FDSupRewardNKey];
        [d setDouble:0 forKey:FDAttentionNKey];
        FDLog(@"daily counters reset to %@", today);
    }
}

// 三段定时状态机（安卓 §4.2）
- (void)loadOrInitPhase {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger mode = (NSInteger)FDNum(FDModeKey, 5);
    double grabMin = FDNum(FDGrabMinKey, 60);
    if (mode == 3) grabMin = 0; // 养号：永远刷视频
    NSInteger phase = (NSInteger)[d doubleForKey:FDPhaseKey];
    double dl = [d doubleForKey:FDPhaseDlKey];
    NSDate *now = [NSDate date];
    if (phase < 0 || phase > 2 || (dl > 0 && [now timeIntervalSince1970] > dl)) {
        // 到点翻转或初次
        if (phase == 1 && grabMin > 0) { phase = 0; dl = now.timeIntervalSince1970 + grabMin * 60; }
        else { phase = 1; dl = now.timeIntervalSince1970 + FDNum(FDBrowseMinKey, 10) * 60; }
    }
    if (dl <= 0) dl = now.timeIntervalSince1970 + 60;
    [d setDouble:phase forKey:FDPhaseKey];
    [d setDouble:dl forKey:FDPhaseDlKey];
    gFDPhase = phase;
}

- (void)flipPhaseIfNeeded {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger mode = (NSInteger)FDNum(FDModeKey, 5);
    double grabMin = FDNum(FDGrabMinKey, 60);
    if (mode == 3) grabMin = 0;
    NSInteger phase = (NSInteger)[d doubleForKey:FDPhaseKey];
    double dl = [d doubleForKey:FDPhaseDlKey];
    NSDate *now = [NSDate date];
    if ([now timeIntervalSince1970] < dl) return; // 未到点

    if (phase == FDPhaseGrab) {
        phase = FDPhaseBrowse;
        dl = now.timeIntervalSince1970 + FDNum(FDBrowseMinKey, 10) * 60;
        [self setStatus:@"阶段：刷视频"];
        FDLog(@"phase -> Browse (%.0fmin)", FDNum(FDBrowseMinKey, 10));
        // 若还在直播间，退回 feed
        [self exitRoomToFeed];
    } else if (phase == FDPhaseBrowse) {
        if (FDNum(FDRestMinKey, 0) > 0) {
            phase = FDPhaseRest;
            dl = now.timeIntervalSince1970 + FDNum(FDRestMinKey, 0) * 60;
            [self setStatus:@"阶段：休息"];
            FDLog(@"phase -> Rest");
        } else if (grabMin > 0) {
            phase = FDPhaseGrab;
            dl = now.timeIntervalSince1970 + grabMin * 60;
            [self setStatus:@"阶段：抢福袋"];
            FDLog(@"phase -> Grab");
            self->_roomSwitches = 0;
        } else {
            phase = FDPhaseBrowse; // 养号
            dl = now.timeIntervalSince1970 + 600;
        }
    } else { // Rest
        if (grabMin > 0) {
            phase = FDPhaseGrab;
            dl = now.timeIntervalSince1970 + grabMin * 60;
            [self setStatus:@"阶段：抢福袋"];
            FDLog(@"phase -> Grab");
            self->_roomSwitches = 0;
        } else {
            phase = FDPhaseBrowse;
            dl = now.timeIntervalSince1970 + 600;
        }
    }
    [d setDouble:phase forKey:FDPhaseKey];
    [d setDouble:dl forKey:FDPhaseDlKey];
    gFDPhase = phase;
}

- (void)poll {
    if (!self->_running || !FDEnabled()) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if ([[FDFloatingController shared] ownsKeyWindow]) return;
    [self resetDailyCountersIfNeeded];
    [self flipPhaseIfNeeded];

    NSInteger mode = (NSInteger)FDNum(FDModeKey, 5);

    FDScanPass *pass = [FDScanPass new];
    if (gFDPhase == FDPhaseGrab) {
        pass.bagContains = @[@"福袋"];
        pass.claimContains = @[@"参与抽奖", @"一键发表评论", @"去发表评论", @"立即参与", @"参与", @"立即抢", @"点击进入直播间"];
        pass.giveupContains = @[@"粉丝团点亮且达到", @"转发", @"分享直播间", @"仅会员可参与", @"不满足参与条件", @"活动已经结束"];
        pass.cleanupContains = @[@"我知道了", @"知道了", @"重新加载", @"领取奖品"];
        pass.a11yNeed = @[@"点赞", @"赞", @"评论", @"关闭"];
    } else {
        pass.a11yNeed = @[@"点赞", @"赞"];
    }
    [FDScanner runPass:pass];

    // 混合页面判定：pass 文本判据 + 顶层 VC 类名（iOS 直播页/广场类名含 Live，feed 含 Feed）
    UIViewController *topVC = FDTopVC();
    NSString *topCls = NSStringFromClass([topVC class]);
    FDPage page = pass.page;
    if (page == FDPageUnknown) {
        BOOL clsLive = ([topCls rangeOfString:@"Live" options:NSCaseInsensitiveSearch].location != NSNotFound);
        BOOL clsFeed = ([topCls rangeOfString:@"Feed" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (clsLive) page = (pass.markerTexts[@"在线观众"] ? FDPageLive : FDPagePlaza);
        else if (clsFeed) page = FDPageVideo;
    }
    static NSInteger sPollTick = 0;
    if (++sPollTick % 30 == 1) FDLog(@"poll: cls=%@ page=%ld phase=%ld roomStage=%ld", topCls, (long)page, (long)gFDPhase, (long)self->_roomStage);

    if (gFDPhase == FDPhaseBrowse) {
        [self browseTick:pass];
        return;
    }
    if (mode == 3) { [self setStatus:@"养号模式 · 刷视频中"]; return; }

    [self grabTick:pass page:page topCls:topCls];
}

#pragma mark Browse：原生自动连播（门卫 hook 生效），引擎只盯页面

- (void)browseTick:(FDScanPass *)pass {
    if (pass.page == FDPageLive) {
        // Browse 期误入直播间 → 退回 feed
        [self exitRoomToFeed];
        [self setStatus:@"刷视频期 · 退出直播间"];
        return;
    }
    NSDate *now = [NSDate date];
    if (!self->_nextFeedAdvance) self->_nextFeedAdvance = [now dateByAddingTimeInterval:FDNum(FDWatchSecKey, 5)];
    if ([now compare:self->_nextFeedAdvance] == NSOrderedAscending) {
        [self setStatus:@"刷视频期 · 观看中"];
        return;
    }
    self->_nextFeedAdvance = [now dateByAddingTimeInterval:FDNum(FDWatchSecKey, 5)];
    [self setStatus:@"刷视频 · 下一个"];
    [self browseAdvanceFeed];
}

// 安卓 UpToAnotherVideo 同款节奏：每条视频固定秒数后切下一个（验证链：官方方法→Row/Item→强滚，全部补发回调）
- (void)browseAdvanceFeed {
    UIScrollView *sv = [FDScanner fullPageVerticalScrollInTopVC];
    if (!sv) { FDLog(@"browse: no feed scroll in topVC"); return; }
    CGPoint before = sv.contentOffset;

    // 路径1：scrollToNextVideo（抖音优化广告跳过模块同款；无效则降级）
    UIViewController *top = FDTopVC();
    SEL sel = NSSelectorFromString(@"scrollToNextVideo");
    if ([top respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [top performSelector:sel];
        #pragma clang diagnostic pop
        __weak UIScrollView *wsv = sv;
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIScrollView *s2 = wsv;
            if (!s2 || !ws) return;
            if (fabs(s2.contentOffset.y - before.y) > 60) { FDLog(@"browse: advanced via scrollToNextVideo"); return; }
            [ws browseAdvanceFallback:1 sv:s2 from:before];
        });
        return;
    }
    [self browseAdvanceFallback:1 sv:sv from:before];
}

- (void)browseAdvanceFallback:(NSInteger)step sv:(UIScrollView *)sv from:(CGPoint)before {
    switch (step) {
        case 1: {
            // 路径2：Table/Collection 官方滚动 API + 补发结束回调
            BOOL scrolled = NO;
            @try {
                NSIndexPath *targetIp = nil;
                if ([sv isKindOfClass:UITableView.class]) {
                    UITableView *tv = (UITableView *)sv;
                    NSInteger page = (NSInteger)round(sv.contentOffset.y / MAX(sv.bounds.size.height, 1));
                    NSInteger n = [tv numberOfRowsInSection:0];
                    if (page + 1 < n) { targetIp = [NSIndexPath indexPathForRow:page + 1 inSection:0]; [tv scrollToRowAtIndexPath:targetIp atScrollPosition:UITableViewScrollPositionTop animated:YES]; scrolled = YES; }
                } else if ([sv isKindOfClass:UICollectionView.class]) {
                    UICollectionView *cv = (UICollectionView *)sv;
                    NSInteger page = (NSInteger)round(sv.contentOffset.y / MAX(sv.bounds.size.height, 1));
                    NSInteger n = 0;
                    id src = cv.dataSource;
                    if (src && [src respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
                        n = ((NSInteger (*)(id, SEL, id, NSInteger))objc_msgSend)(src, @selector(collectionView:numberOfItemsInSection:), cv, 0);
                    }
                    if (page + 1 < n) { targetIp = [NSIndexPath indexPathForItem:page + 1 inSection:0]; ((void (*)(id, SEL, id, NSInteger, NSInteger, BOOL))objc_msgSend)(cv, @selector(scrollToItemAtIndexPath:atScrollPosition:animated:), targetIp, UICollectionViewScrollPositionTop, 0, YES); scrolled = YES; }
                }
            } @catch (NSException *e) {
                FDLog(@"browse: row/item exception %@", e);
            }
            if (scrolled) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self fireScrollEndFor:sv];
                });
                [self verifyBrowseAdvance:step sv:sv from:before];
                return;
            }
            [self browseAdvanceFallback:2 sv:sv from:before];
            return;
        }
        default: {
            // 路径3：强滚 + 补发结束回调
            CGPoint off = sv.contentOffset;
            off.y += sv.bounds.size.height;
            [sv setContentOffset:off animated:NO];
            [self fireScrollEndFor:sv];
            FDLog(@"browse: fallback scrolled y=%.0f + end callback", off.y);
            return;
        }
    }
}

- (void)verifyBrowseAdvance:(NSInteger)step sv:(UIScrollView *)sv from:(CGPoint)before {
    __weak UIScrollView *wsv = sv;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *s2 = wsv;
        if (!s2 || !ws) return;
        if (fabs(s2.contentOffset.y - before.y) > 60) { FDLog(@"browse: advanced step %ld", (long)step); return; }
        [ws browseAdvanceFallback:step + 1 sv:s2 from:before];
    });
}

- (void)fireScrollEndFor:(UIScrollView *)sv {
    id del = sv.delegate;
    if (del && [del respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(del, @selector(scrollViewDidEndDecelerating:), sv);
        FDLog(@"browse: fired scroll end");
    }
}

#pragma mark Grab：进房 + 房内循环 + 抢

- (void)grabTick:(FDScanPass *)pass page:(FDPage)page topCls:(NSString *)topCls {
    static NSInteger sLogTick = 0;
    if (++sLogTick % 5 == 1) {
        FDLog(@"grab: page=%ld bag=%d claim=%d cleanup=%d markers=%@",
              (long)page, pass.bagHit != nil, pass.claimHit != nil, pass.cleanupHit != nil,
              pass.markerTexts.allKeys);
    }

    // 1) 弹窗/开奖结果优先（安卓 closeRegBagNote）
    if (pass.cleanupHit) {
        NSString *txt = pass.cleanupHit.accessibilityLabel ?: @"";
        if ([txt rangeOfString:@"领取奖品"].location != NSNotFound) {
            [self noteReward:txt];
        } else {
            FDLog(@"room: popup cleanup");
        }
        [FDTap tapView:pass.cleanupHit];
        self->_noBagTicks = 0;
        return;
    }

    // 2) 页面路由
    if (page == FDPageLive) {
        [self roomTick:pass];
        return;
    }
    if (page == FDPagePlaza) {
        [self plazaTick];
        return;
    }
    if (page == FDPageVideo || page == FDPageMenu || page == FDPageUser) {
        // 抢福袋期也要刷 feed：直播预览卡是刷出来的，停着不动永远遇不到
        NSDate *nowAdv = [NSDate date];
        if (!self->_nextFeedAdvance) self->_nextFeedAdvance = [nowAdv dateByAddingTimeInterval:FDNum(FDWatchSecKey, 5)];
        if ([nowAdv compare:self->_nextFeedAdvance] == NSOrderedDescending) {
            self->_nextFeedAdvance = [nowAdv dateByAddingTimeInterval:FDNum(FDWatchSecKey, 5)];
            [self setStatus:@"抢福袋期 · 刷feed找直播"];
            [self browseAdvanceFeed];
        }
        [self enterRoomFromFeed];
        return;
    }

    // 3) Unknown：连续 5 tick → 深链回推荐页纠偏
    self->_unknownTicks++;
    if (self->_unknownTicks >= 5) {
        self->_unknownTicks = 0;
        [self setStatus:@"页面异常 · 回推荐页"];
        FDLog(@"grab: unknown page (top=%@), deep-link to feed", topCls);
        [self exitRoomToFeed];
    }
}

// 直播广场：点屏幕上半部Probe点的第一张大卡（iOS 广场没有安卓的"点击进入直播间"提示文字）
- (void)plazaTick {
    if (self->_nextEnterTry && [[NSDate date] compare:self->_nextEnterTry] == NSOrderedAscending) return;
    self->_nextEnterTry = [NSDate dateWithTimeIntervalSinceNow:10.0];
    CGSize screen = UIScreen.mainScreen.bounds.size;
    UIScrollView *pager = [FDScanner fullPageVerticalScrollInTopVC];
    UIView *card = nil;
    if (pager) {
        CGPoint probe = CGPointMake(screen.width * 0.5, screen.height * 0.35);
        NSMutableArray *stack = [NSMutableArray arrayWithObject:pager];
        NSInteger budget = 400;
        while (stack.count > 0 && budget > 0 && !card) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            budget--;
            if (![v isKindOfClass:UIView.class]) continue;
            if (v != pager) {
                if (v.hidden || v.alpha < 0.2) continue;
                CGRect absRect = [v convertRect:v.bounds toView:nil];
                if (CGRectContainsPoint(absRect, probe) &&
                    v.bounds.size.width > screen.width * 0.3 &&
                    v.bounds.size.height > screen.height * 0.15) {
                    card = v;
                    break;
                }
            }
            for (UIView *s in [v.subviews reverseObjectEnumerator]) [stack addObject:s];
        }
    }
    if (card && [FDTap tapView:card]) {
        [self setStatus:@"直播广场 · 进房"];
        FDLog(@"plaza: card tapped %@", NSStringFromClass([card class]));
    } else {
        FDLog(@"plaza: no card found, back to feed");
        [self exitRoomToFeed];
    }
}

- (UIView *)findPlazaCardHint {
    // 直播广场卡片提示"点击进入直播间"——在 pass 里没直接存 view，这里轻量复查（复用 deadline 机制）
    FDScanPass *p = [FDScanPass new];
    p.claimContains = @[@"点击进入直播间"];
    p.deadline = CFAbsoluteTimeGetCurrent() + 0.06;
    [FDScanner runPass:p];
    return p.claimHit;
}

- (void)enterRoomFromFeed {
    if (self->_nextEnterTry && [[NSDate date] compare:self->_nextEnterTry] == NSOrderedAscending) return;
    self->_nextEnterTry = [NSDate dateWithTimeIntervalSinceNow:8.0];
    // ⓪ 直播预览卡（feed 里嵌的直播间，带"点击进入直播间"按钮）——最优先，按钮可直接点
    @try {
        FDScanPass *pv = [FDScanPass new];
        pv.claimContains = @[@"点击进入直播间", @"进入直播间"];
        pv.deadline = CFAbsoluteTimeGetCurrent() + 0.12;
        [FDScanner runPass:pv];
        if (pv.claimHit && [FDTap tapView:pv.claimHit]) {
            [self setStatus:@"进房：直播预览卡"];
            FDLog(@"enter: live preview card tapped");
            [self verifyEntryThenDeeplink];
            return;
        }
    } @catch (NSException *e) { }
    // ① 直播 tab：iOS 底部 tab 标题/标签为 "直播"；兼容安卓式 "直播，" 前缀
    UIView *tab = [self findLiveTab];
    if (tab) {
        if ([FDTap tapView:tab]) {
            [self setStatus:@"进房：切直播 tab"];
            FDLog(@"enter: live tab tapped, verifying");
            [self verifyEntryThenDeeplink];
            return;
        }
    }
    // ② 没找到 tab：推荐页上可能直接有"直播中"卡片徽标（点它同样能进直播间）
    UIView *badge = nil;
    @try {
        FDScanPass *p = [FDScanPass new];
        p.claimContains = @[@"直播中"];
        p.deadline = CFAbsoluteTimeGetCurrent() + 0.05;
        [FDScanner runPass:p];
        badge = p.claimHit;
    } @catch (NSException *e) { }
    if (badge && [FDTap tapView:badge]) {
        [self setStatus:@"进房：直播卡片"];
        FDLog(@"enter: live badge tapped, verifying");
        [self verifyEntryThenDeeplink];
        return;
    }
    // ③ 深链进直播间（轮换候选路由，成功的会被记住优先用）
    [self openLiveDeepLink];
}

// 点了 tab/卡片后 3 秒复查：页面没切到直播 → 深链兜底
- (void)verifyEntryThenDeeplink {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(ws) strongSelf = ws;
        if (!strongSelf || !strongSelf->_running) return;
        UIViewController *top = FDTopVC();
        NSString *cls = NSStringFromClass([top class]);
        if ([cls rangeOfString:@"Live" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            FDLog(@"enter: verified live page (%@)", cls);
            return;
        }
        FDLog(@"enter: page still %@ after tab tap, deep link fallback", cls);
        [ws openLiveDeepLink];
    });
}

// 深链轮换：候选路由逐个试，成功的记入 fudai.liveSchemeOK 优先使用
- (void)openLiveDeepLink {
    NSArray *schemes = @[@"snssdk1128://live", @"snssdk1128://livesimple", @"sslocal://live", @"snssdk1128://aweme/live"];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger okIdx = (NSInteger)[d doubleForKey:@"fudai.liveSchemeOK"];
    NSInteger idx = (NSInteger)[d doubleForKey:@"fudai.liveSchemeIdx"];
    if (okIdx >= 0 && okIdx < (NSInteger)schemes.count) {
        // 已验证可用的优先（首次命中只是"疑似"，连续两次确认才保持）
        NSString *scheme = schemes[okIdx];
        NSURL *u = [NSURL URLWithString:scheme];
        if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
        [self setStatus:[NSString stringWithFormat:@"进房：深链(%ld)", (long)okIdx]];
        FDLog(@"enter: deep link (known-good) %@", scheme);
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(ws) strongSelf = ws;
            if (!strongSelf || !strongSelf->_running) return;
            UIViewController *top = FDTopVC();
            NSString *cls = NSStringFromClass([top class]);
            if ([cls rangeOfString:@"Live" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                FDLog(@"enter: known-good scheme failed again, clearing");
                [d setDouble:-1 forKey:@"fudai.liveSchemeOK"];
                [d setDouble:okIdx + 1 >= (double)schemes.count ? 0 : okIdx + 1 forKey:@"fudai.liveSchemeIdx"];
            }
        });
        return;
    }
    if (idx >= (NSInteger)schemes.count) idx = 0;
    NSString *scheme = schemes[idx];
    NSURL *u = [NSURL URLWithString:scheme];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    [self setStatus:[NSString stringWithFormat:@"进房：深链试 %ld", (long)idx]];
    FDLog(@"enter: deep link candidate %ld %@", (long)idx, scheme);
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(ws) strongSelf = ws;
        if (!strongSelf || !strongSelf->_running) return;
        UIViewController *top = FDTopVC();
        NSString *cls = NSStringFromClass([top class]);
        if ([cls rangeOfString:@"Live" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSInteger pend = (NSInteger)[d doubleForKey:@"fudai.liveSchemePending"];
            if (pend == idx) {
                [d setDouble:idx forKey:@"fudai.liveSchemeOK"];
                [d setDouble:-1 forKey:@"fudai.liveSchemePending"];
                FDLog(@"enter: deep link %ld CONFIRMED twice, saved", (long)idx);
            } else {
                [d setDouble:idx forKey:@"fudai.liveSchemePending"];
                FDLog(@"enter: deep link %ld first hit, pending confirm", (long)idx);
            }
        } else {
            [d setDouble:-1 forKey:@"fudai.liveSchemePending"];
            [d setDouble:idx + 1 forKey:@"fudai.liveSchemeIdx"];
            FDLog(@"enter: deep link %ld landed on %@, rotating", (long)idx, cls);
        }
    });
}

- (void)verifyDeepLinkLanded:(NSInteger)idx {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(ws) strongSelf = ws;
        if (!strongSelf || !strongSelf->_running) return;
        UIViewController *top = FDTopVC();
        NSString *cls = NSStringFromClass([top class]);
        if ([cls rangeOfString:@"Live" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            FDLog(@"enter: deep link landed live (%@)", cls);
        } else {
            FDLog(@"enter: deep link landed on %@ (not live)", cls);
        }
    });
}

- (UIView *)findLiveTab {
    // iOS：底部 UITabBarButton 的标题/标签是 "直播"；a11y 匹配 contains "直播"（会命中 tab 及
    // 页面上其他含"直播"的小控件，下面用精确校验过滤）
    FDScanPass *p = [FDScanPass new];
    p.a11yNeed = @[@"直播"];
    p.deadline = CFAbsoluteTimeGetCurrent() + 0.05;
    [FDScanner runPass:p];
    UIView *hit = p.a11yHits[@"直播"];
    if (hit) {
        NSString *s = hit.accessibilityLabel ?: @"";
        NSString *title = @"";
        if ([hit isKindOfClass:UIButton.class]) title = [(UIButton *)hit currentTitle] ?: @"";
        if ([s isEqualToString:@"直播"] || [s hasPrefix:@"直播，"] || [title isEqualToString:@"直播"]) {
            return hit;
        }
    }
    return nil;
}

- (void)roomTick:(FDScanPass *)pass {
    if (self->_roomStage == FDRoomSwitchWait) return; // 换房进行中，等 doRoomSwitch
    // 弹窗清理由 grabTick 完成（cleanup 优先），这里处理福袋
    if (pass.bagHit) {
        self->_noBagTicks = 0;
        NSString *bagText = ([pass.bagHit isKindOfClass:UILabel.class] ? [(UILabel *)pass.bagHit text] : @"") ?: @"";
        // 人数过滤
        NSString *aud = pass.markerTexts[@"在线观众"];
        if (aud.length && FDBool(FDFilterRoomKey, NO)) {
            long long cnt = [self parseAudienceCount:aud];
            if (cnt > 0 && cnt > (long long)FDNum(FDMaxRoomKey, 200000)) {
                [self setStatus:@"人数超限 · 换房"];
                [self scheduleRoomSwitch];
                return;
            }
        }
        NSInteger seconds = FDParseSeconds(bagText);
        BOOL isSuper = [bagText rangeOfString:@"超级福袋"].location != NSNotFound;
        NSInteger mode = (NSInteger)FDNum(FDModeKey, 5);
        // 类型/时长/限额过滤（安卓 §4.5）
        if (isSuper) {
            if (mode == 1) { [self scheduleRoomSwitch]; return; }
            if (seconds > (NSInteger)FDNum(FDSupLimitMinKey, 15) * 60) { [self setStatus:@"超级福袋时间太长 · 换房"]; [self scheduleRoomSwitch]; return; }
            if (FDNum(FDSupAttendNKey, 0) >= FDNum(FDSupAttendKey, 100)) { [self setStatus:@"超级福袋参与超限 · 换房"]; [self scheduleRoomSwitch]; return; }
        } else {
            if (mode == 0) { [self scheduleRoomSwitch]; return; }
            if (seconds > (NSInteger)FDNum(FDDiaLimitMinKey, 4) * 60) { [self setStatus:@"福袋时间太长 · 换房"]; [self scheduleRoomSwitch]; return; }
            if (FDNum(FDDiaAttendNKey, 0) >= FDNum(FDDiaAttendKey, 50)) { [self setStatus:@"福袋参与超限 · 换房"]; [self scheduleRoomSwitch]; return; }
        }
        // 进面板
        if (self->_roomStage != FDRoomPanel) {
            [self setStatus:isSuper ? @"发现超级福袋 · 进面板" : @"发现福袋 · 进面板"];
            FDLog(@"room: bag tapped '%@' sec=%ld", bagText, (long)seconds);
            if ([FDTap tapView:pass.bagHit]) {
                self->_roomStage = FDRoomPanel;
                self->_bagType = isSuper ? 2 : 0;
                double mins = isSuper ? FDNum(FDSupLimitMinKey, 15) : 10.0;
                self->_panelDeadline = [NSDate dateWithTimeIntervalSinceNow:mins * 60];
                self->_likedThisRoom = NO; self->_commentedThisRoom = NO; self->_superLikeDone = NO;
            }
        }
        return;
    }

    // 面板已开 → 面板流程
    if (self->_roomStage == FDRoomPanel) {
        [self panelTick:pass];
        return;
    }

    // 没福袋 → 换房（等 waitNextRoom 秒）
    self->_noBagTicks++;
    if (self->_noBagTicks >= MAX((NSInteger)FDNum(FDWaitRoomKey, 5), 3)) {
        [self setStatus:@"本房无福袋 · 换房"];
        [self scheduleRoomSwitch];
    }
}

- (long long)parseAudienceCount:(NSString *)text {
    if (!text.length) return 0;
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *digits = [[text componentsSeparatedByCharactersInSet:nonDigit] componentsJoinedByString:@""];
    if (digits.length == 0) return 0;
    long long v = digits.longLongValue;
    if ([text rangeOfString:@"万"].location != NSNotFound) v = (long long)([digits doubleValue] * 10000);
    return v;
}

- (void)scheduleRoomSwitch {
    if (self->_nextRoomSwitch && [[NSDate date] compare:self->_nextRoomSwitch] == NSOrderedAscending) return;
    self->_nextRoomSwitch = [NSDate dateWithTimeIntervalSinceNow:1.0];
    self->_roomSwitches++;
    if (self->_roomSwitches > (NSInteger)FDNum(FDMaxSwitchKey, 60)) {
        FDLog(@"room: switch limit reached, back to feed");
        self->_roomSwitches = 0;
        [self exitRoomToFeed];
        return;
    }
    self->_roomStage = FDRoomSwitchWait;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FDNum(FDWaitRoomKey, 5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_running) return;
        [self doRoomSwitch];
    });
}

// 上滑换房：直播间容器翻页（验证）→ 失败退回 feed 重进
- (void)doRoomSwitch {
    UIScrollView *pager = [FDScanner fullPageVerticalScrollInTopVC];
    if (pager) {
        CGPoint before = pager.contentOffset;
        CGPoint off = pager.contentOffset;
        off.y += pager.bounds.size.height;
        [pager setContentOffset:off animated:NO];
        [self fireScrollEndFor:pager];
        __weak UIScrollView *wsv = pager;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIScrollView *s2 = wsv;
            if (!s2) return;
            if (fabs(s2.contentOffset.y - before.y) > 60) {
                FDLog(@"room: swiped to next room");
                self->_roomStage = FDRoomScan;
                self->_noBagTicks = 0;
                return;
            }
            FDLog(@"room: pager no movement, exit to feed");
            [self exitRoomToFeed];
        });
        return;
    }
    [self exitRoomToFeed];
}

- (void)exitRoomToFeed {
    UIViewController *top = FDTopVC();
    BOOL exited = NO;
    if (top.navigationController && top.navigationController.viewControllers.count > 1) {
        [top.navigationController popViewControllerAnimated:YES];
        exited = YES;
    }
    if (!exited) {
        NSURL *u = [NSURL URLWithString:@"snssdk1128://feed/"];
        if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }
    self->_roomStage = FDRoomScan;
    self->_noBagTicks = 0;
    self->_roomSwitches = 0;
    self->_nextEnterTry = [NSDate dateWithTimeIntervalSinceNow:6.0];
}

#pragma mark 面板流程（普通/超级，安卓 §4.7.1/4.7.2 精简照抄）

- (void)panelTick:(FDScanPass *)pass {
    if ([[NSDate date] compare:self->_panelDeadline] == NSOrderedDescending) {
        FDLog(@"panel: deadline exceeded, switch room");
        self->_roomStage = FDRoomScan;
        [self scheduleRoomSwitch];
        return;
    }
    // 放弃条件（安卓 §4.7.3）
    if (pass.giveupHit) {
        [self setStatus:@"参与条件不满足 · 换房"];
        FDLog(@"panel: condition blocked");
        self->_roomStage = FDRoomScan;
        [self scheduleRoomSwitch];
        return;
    }

    BOOL joined = NO;
    for (NSString *t in pass.panelTexts) {
        if ([t rangeOfString:@"已参与"].location != NSNotFound ||
            [t rangeOfString:@"参与成功"].location != NSNotFound ||
            [t rangeOfString:@"等待开奖"].location != NSNotFound) { joined = YES; break; }
    }

    if (pass.cleanupHit) {
        NSString *txt = pass.cleanupHit.accessibilityLabel ?: @"";
        if ([txt rangeOfString:@"领取奖品"].location != NSNotFound || [txt rangeOfString:@"恭喜"].location != NSNotFound) {
            [self noteReward:txt];
        } else {
            FDLog(@"panel: result popup (lose) tapped");
            [self noteLose];
        }
        [FDTap tapView:pass.cleanupHit];
        self->_roomStage = FDRoomScan;
        [self scheduleRoomSwitch];
        return;
    }

    if (joined) {
        [self setStatus:@"已参与 · 挂机等开奖"];
        [self waitingEngagement:pass];
        return;
    }

    // 金额过滤（超级福袋：参考价值）
    if (self->_bagType == 2) {
        double price = 0;
        for (NSString *t in pass.panelTexts) {
            NSRange r = [t rangeOfString:@"参考价值"];
            if (r.location != NSNotFound) {
                NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                NSString *digits = [[t componentsSeparatedByCharactersInSet:nonDigit] componentsJoinedByString:@""];
                if (digits.length >= 2) price = [[digits substringFromIndex:1] doubleValue];
                if (price <= 0) price = digits.doubleValue;
                break;
            }
        }
        if (price > 0) {
            if (price < FDNum(FDMinSuperKey, 50) || price > FDNum(FDMaxSuperKey, 99999)) {
                [self setStatus:[NSString stringWithFormat:@"参考价 %.0f 元 · 放弃", price]];
                FDLog(@"panel: price %.0f out of range", price);
                self->_roomStage = FDRoomScan;
                [self scheduleRoomSwitch];
                return;
            }
            FDLog(@"panel: super price=%.0f ok", price);
        }
    }

    // 参与按钮（5 秒防重）
    if (pass.claimHit) {
        if (self->_claimedAt && [[NSDate date] timeIntervalSinceDate:self->_claimedAt] < 5.0) {
            [self setStatus:@"参与点击确认中"];
            return;
        }
        self->_claimedAt = [NSDate date];
        if (self->_bagType == 2) FDNumIncrement(FDSupAttendNKey); else FDNumIncrement(FDDiaAttendNKey);
        [self setStatus:@"点击参与"];
        FDLog(@"panel: claim tapped");
        if ([FDTap tapView:pass.claimHit]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FDScanPass *p2 = [FDScanPass new];
                p2.claimContains = @[@"发送"];
                p2.deadline = CFAbsoluteTimeGetCurrent() + 0.06;
                [FDScanner runPass:p2];
                if ([p2.claimHit isKindOfClass:UIControl.class]) {
                    [(UIControl *)p2.claimHit sendActionsForControlEvents:UIControlEventTouchUpInside];
                    FDLog(@"panel: comment sent after claim");
                }
            });
        }
        self->_joinedDeadline = [NSDate dateWithTimeIntervalSinceNow:1200];
        return;
    }

    [self setStatus:@"面板扫描中"];
    [self waitingEngagement:pass];
}

- (void)noteReward:(NSString *)txt {
    if (self->_bagType == 2) FDNumIncrement(FDSupRewardNKey); else FDNumIncrement(FDDiaRewardNKey);
    [self setStatus:@"中奖了！🎉"];
    FDLog(@"reward: %@", txt);
}

- (void)noteLose {
    // 连续不中奖换房逻辑保留扩展位
}

- (void)waitingEngagement:(FDScanPass *)pass {
    // 剩余 >30s 时：点赞（30%概率 5~50 次，仅一次）+ 评论（概率，仅一次）
    NSInteger remain = 0;
    for (NSString *t in pass.panelTexts) {
        NSInteger s = FDParseSeconds(t);
        if (s > 0) { remain = s; break; }
    }
    if (remain > 0 && remain <= 30) return;
    NSInteger roll = FDRand(1, 100);
    if (!self->_likedThisRoom && (double)roll <= FDNum(FDLikeRateKey, 30)) {
        UIView *like = pass.a11yHits[@"点赞"] ?: pass.a11yHits[@"赞"];
        if (like) {
            NSInteger times = FDRand((NSInteger)FDNum(FDLikeMinKey, 5), (NSInteger)FDNum(FDLikeMaxKey, 50));
            for (NSInteger i = 0; i < times; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [FDTap tapView:like];
                });
            }
            self->_likedThisRoom = YES;
            FDLog(@"room: like burst x%ld", (long)times);
        }
    }
    roll = FDRand(1, 100);
    if (!self->_commentedThisRoom && (double)roll <= FDNum(FDCmtRateKey, 0)) {
        UIView *cmt = pass.a11yHits[@"评论"];
        if (cmt) {
            self->_commentedThisRoom = YES;
            [FDTap tapView:cmt];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FDScanPass *p2 = [FDScanPass new];
                p2.deadline = CFAbsoluteTimeGetCurrent() + 0.06;
                [FDScanner runPass:p2];
                UIView *field = p2.textField;
                if ([field isKindOfClass:UITextField.class]) {
                    ((UITextField *)field).text = [self commentTemplates].firstObject ?: @"真好啊";
                } else if ([field isKindOfClass:UITextView.class]) {
                    UITextView *tv = (UITextView *)field;
                    [tv becomeFirstResponder];
                    tv.text = [self commentTemplates].firstObject ?: @"真好啊";
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FDScanPass *p3 = [FDScanPass new];
                    p3.claimContains = @[@"发送"];
                    p3.deadline = CFAbsoluteTimeGetCurrent() + 0.06;
                    [FDScanner runPass:p3];
                    if ([p3.claimHit isKindOfClass:UIControl.class]) {
                        [(UIControl *)p3.claimHit sendActionsForControlEvents:UIControlEventTouchUpInside];
                        FDLog(@"room: comment sent");
                    }
                });
            });
        }
    }
}

- (NSArray<NSString *> *)commentTemplates {
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *part in [FDStr(FDCommentsKey, @"主播太帅了/真好/太完美了/优秀/Perfect!") componentsSeparatedByString:@"/"]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [list addObject:t];
    }
    return list;
}

static void FDNumIncrement(NSString *key) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setDouble:[d doubleForKey:key] + 1 forKey:key];
}

#pragma mark LuckyBox hook 联动（保留精准信号）

- (void)noteLuckySignalOnInstance:(id)manager {
    self->_lastLuckySignal = [NSDate date];
    if (gFDPhase != FDPhaseGrab || self->_roomStage != FDRoomScan) return;
    SEL open = NSSelectorFromString(@"openGrabLuckyBoxView");
    if (manager && [manager respondsToSelector:open]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_running || self->_roomStage != FDRoomScan) return;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [manager performSelector:open];
            #pragma clang diagnostic pop
            self->_roomStage = FDRoomPanel;
            self->_bagType = 0;
            self->_panelDeadline = [NSDate dateWithTimeIntervalSinceNow:600];
            [self setStatus:@"发现福袋 · 进面板"];
            FDLog(@"luckybox: panel opened via manager");
        });
    }
}

- (void)noteRoomModel:(id)roomModel {
    if (!roomModel) return;
    @try {
        for (NSString *key in @[@"userCount", @"audienceCount", @"memberCount", @"totalUserCount", @"watchCount"]) {
            id v = [roomModel valueForKey:key];
            if ([v isKindOfClass:NSNumber.class]) {
                self->_roomSize = [(NSNumber *)v longLongValue];
                FDLog(@"room size=%lld", self->_roomSize);
                return;
            }
        }
    } @catch (NSException *e) { }
}

- (void)noteDiamondFromManager:(id)manager {
    @try {
        id item = [manager valueForKey:@"shortTouchItem"];
        if (!item) return;
        id v = [item valueForKey:@"diamondCount"];
        if ([v isKindOfClass:NSNumber.class]) {
            self->_lastDiamond = [(NSNumber *)v longLongValue];
            FDLog(@"diamond=%lld", self->_lastDiamond);
        }
    } @catch (NSException *e) { }
}
@end

#pragma mark - 悬浮窗 + 设置面板

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
        FDLog(@"floating installed");
    });
}

- (NSArray<UIWindow *> *)fdWindows {
    NSMutableArray *arr = [NSMutableArray array];
    if (self->_window) [arr addObject:self->_window];
    if (self->_panelWindow) [arr addObject:self->_panelWindow];
    return arr;
}

- (BOOL)ownsKeyWindow {
    for (UIWindow *w in [self fdWindows]) if (w.isKeyWindow) return YES;
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

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 200, 22)];
    title.text = @"福袋助手 0.7";
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
    [card addSubview:scroll];
    self->_fields = [NSMutableDictionary dictionary];
    CGFloat y = 8;

    y = [self switchRowIn:scroll y:y key:FDEnabledKey label:@"总开关"];
    y = [self numRowIn:scroll y:y key:FDModeKey label:@"模式(0超1币2关3养4手5全)" def:@5];
    y = [self numRowIn:scroll y:y key:FDGrabMinKey label:@"抢福袋时长(分,0=养号)" def:@60];
    y = [self numRowIn:scroll y:y key:FDBrowseMinKey label:@"刷视频时长(分)" def:@10];
    y = [self numRowIn:scroll y:y key:FDRestMinKey label:@"休息时长(分)" def:@0];
    y = [self numRowIn:scroll y:y key:FDDiaAttendKey label:@"抖币福袋参与上限" def:@50];
    y = [self numRowIn:scroll y:y key:FDDiaRewardKey label:@"抖币中奖上限" def:@5];
    y = [self numRowIn:scroll y:y key:FDDiaLimitMinKey label:@"抖币袋超时(分)放弃" def:@4];
    y = [self numRowIn:scroll y:y key:FDSupAttendKey label:@"超级福袋参与上限" def:@100];
    y = [self numRowIn:scroll y:y key:FDSupLimitMinKey label:@"超级袋超时(分)放弃" def:@15];
    y = [self numRowIn:scroll y:y key:FDMinSuperKey label:@"参考价下限(元)" def:@50];
    y = [self numRowIn:scroll y:y key:FDMaxSuperKey label:@"参考价上限(元)" def:@99999];
    y = [self switchRowIn:scroll y:y key:FDFilterRoomKey label:@"启用人数过滤"];
    y = [self numRowIn:scroll y:y key:FDMaxRoomKey label:@"只抢X人以内" def:@200000];
    y = [self numRowIn:scroll y:y key:FDWaitRoomKey label:@"换房等待(秒)" def:@5];
    y = [self numRowIn:scroll y:y key:FDMaxSwitchKey label:@"换房次数上限" def:@60];
    y = [self numRowIn:scroll y:y key:FDLikeRateKey label:@"直播间点赞概率%" def:@30];
    y = [self numRowIn:scroll y:y key:FDLikeMinKey label:@"点赞次数min" def:@5];
    y = [self numRowIn:scroll y:y key:FDLikeMaxKey label:@"点赞次数max" def:@50];
    y = [self numRowIn:scroll y:y key:FDCmtRateKey label:@"直播间评论概率%" def:@0];
    y = [self numRowIn:scroll y:y key:FDAttendModeKey label:@"参与时机(6=立马)" def:@6];
    y = [self switchRowIn:scroll y:y key:FDFansTeamKey label:@"允许加粉丝团"];
    y = [self numRowIn:scroll y:y key:FDFansYuanKey label:@"加团条件参考价(元)" def:@2000];
    y = [self switchRowIn:scroll y:y key:FDAutoplayKey label:@"原生自动连播(视频播完自切)"];
    y = [self numRowIn:scroll y:y key:FDWatchSecKey label:@"刷视频秒/条(强切)" def:@5];
    y = [self fieldRowIn:scroll y:y key:FDSearchKey label:@"搜索关键词" value:FDStr(FDSearchKey, @"带货直播间")];
    y = [self fieldRowIn:scroll y:y key:FDCommentsKey label:@"评论模板(/分隔)" value:FDStr(FDCommentsKey, @"主播太帅了/真好/太完美了/优秀/Perfect!")];
    y = [self switchRowIn:scroll y:y key:FDDebugKey label:@"调试日志(落盘)"];

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
    sw.on = FDBool(key, NO);
    sw.onTintColor = [UIColor colorWithRed:0.20 green:0.72 blue:0.40 alpha:1.0];
    sw.accessibilityIdentifier = key;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
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

- (CGFloat)numRowIn:(UIScrollView *)scroll y:(CGFloat)y key:(NSString *)key label:(NSString *)label def:(NSNumber *)def {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 4, 150, 18)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:11];
    l.adjustsFontSizeToFitWidth = YES;
    [scroll addSubview:l];
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(180, y, 100, 30)];
    double v = [NSUserDefaults.standardUserDefaults objectForKey:key] ? [NSUserDefaults.standardUserDefaults doubleForKey:key] : def.doubleValue;
    f.text = [NSString stringWithFormat:@"%g", v];
    f.textColor = UIColor.whiteColor;
    f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    f.textAlignment = NSTextAlignmentCenter;
    f.font = [UIFont systemFontOfSize:13];
    [f addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [scroll addSubview:f];
    self->_fields[key] = f;
    return y + 38;
}

- (CGFloat)fieldRowIn:(UIScrollView *)scroll y:(CGFloat)y key:(NSString *)key label:(NSString *)label value:(NSString *)v {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 2, 240, 18)];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:11];
    [scroll addSubview:l];
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(16, y + 22, 268, 30)];
    f.text = v ?: @"";
    f.textColor = UIColor.whiteColor;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    f.font = [UIFont systemFontOfSize:13];
    [f addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingDidEnd];
    [scroll addSubview:f];
    self->_fields[key] = f;
    return y + 60;
}

- (void)fieldChanged:(UITextField *)f { [self saveAll]; }

- (void)saveAll {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *key in self->_fields) {
        UITextField *f = self->_fields[key];
        if (!f.text.length) continue;
        if ([key isEqualToString:FDSearchKey] || [key isEqualToString:FDCommentsKey]) {
            [d setObject:f.text forKey:key];
        } else {
            [d setDouble:[f.text doubleValue] forKey:key];
        }
    }
}

- (void)generateDiagnostics:(UIButton *)sender {
    sender.enabled = NO;
    FDDumpRuntimeInfo();
    sender.enabled = YES;
    if (self->_statusLabel) self->_statusLabel.text = @"已写入 Documents/fudai_dump.txt";
}

- (void)refreshUI {
    BOOL on = FDEnabled();
    [_button setTitle:(on ? @"福袋 · 开" : @"福袋 · 关") forState:UIControlStateNormal];
    if (_statusLabel && !_lastExternalStatus) {
        _statusLabel.text = on
            ? [NSString stringWithFormat:@"运行中 · 参与 %ld 次", (long)[[FDCoordinator shared] dailyCount]]
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

#pragma mark - Hooks

// ★ 刷视频：抖音优化 28.52 同款门卫（原生自动连播接管，照抄最小清单）
// 每个宿主类独立分组，类不存在则跳过（28.52 分析 §4.2 的 5 个 hook）
static BOOL FDAutoPlayGate(void) { return FDAutoPlayActive(); }

%group GAutoPlay1
%hook AWEAwemeDetailTableViewController
- (BOOL)hasIphoneAutoPlaySwitch {
    if (FDAutoPlayGate()) return YES;
    return %orig;
}
%end
%end

%group GAutoPlay2
%hook AWEAwemeDetailContainerPlayControlConfig
- (BOOL)enableUserProfilePostAutoPlay {
    if (FDAutoPlayGate()) return YES;
    return %orig;
}
%end
%end

%group GAutoPlay3
%hook AWEFeedIPhoneAutoPlayManager
- (BOOL)isAutoPlayOpen {
    if (FDAutoPlayGate()) return YES;
    return %orig;
}
- (NSInteger)getFeedIphoneAutoPlayState {
    if (FDAutoPlayGate()) return 1;
    return %orig;
}
%end
%end

%group GAutoPlay4
%hook AWEFeedModuleService
- (NSInteger)getFeedIphoneAutoPlayState {
    if (FDAutoPlayGate()) return 1;
    return %orig;
}
%end
%end

// 观察者（私聊红包，保留）
%group GObserveIM
%hook AWEIMDouyinRedPacketComponent
- (void)redPacketDidTapped {
    [[FDCoordinator shared] noteLuckySignalOnInstance:nil];
    %orig;
}
%end
%end

// 直播福袋核心（LuckyBox 管理器：精准信号 + 直开面板 + 房间数据）
%group GLuckyBoxManager
%hook IESLiveLuckyBoxServiceManager
- (void)messageReceived:(id)message {
    %orig;
    [[FDCoordinator shared] noteLuckySignalOnInstance:self];
}
- (void)createLuckyBoxShortTouchItem:(id)item aniViewData:(id)aniViewData isShowEntranceAnimation:(BOOL)animate {
    %orig;
    [[FDCoordinator shared] noteLuckySignalOnInstance:self];
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

static BOOL gAutoPlay1, gAutoPlay2, gAutoPlay3, gAutoPlay4, gObserveIM, gLuckyBox, gAutoPlayLogged;

static void FDDumpRuntimeInfo(void) {
    @autoreleasepool {
        NSArray *keywords = @[@"RedPacket", @"LuckyBag", @"HongBao", @"Lucky", @"Lottery",
                              @"LuckyBox", @"Rush", @"FuDai", @"AutoPlay"];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"totalClasses=%u\n", count];
        [out appendFormat:@"IESLiveLuckyBoxServiceManager=%@\n",
            NSClassFromString(@"IESLiveLuckyBoxServiceManager") ? @"FOUND" : @"MISSING"];
        [out appendFormat:@"AWEFeedIPhoneAutoPlayManager=%@\n",
            NSClassFromString(@"AWEFeedIPhoneAutoPlayManager") ? @"FOUND" : @"MISSING"];
        [out appendFormat:@"AWEFeedTableViewController=%@\n",
            NSClassFromString(@"AWEFeedTableViewController") ? @"FOUND" : @"MISSING"];
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
        [out writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[FuDai] dump -> %@", file);
    }
}

static void FDWriteBootMarker(void) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"boot=%@\n", [NSDate date]];
        [out appendFormat:@"bundle=%@\n", NSBundle.mainBundle.bundleIdentifier ?: @"(nil)"];
        [out appendFormat:@"enabled=%@ debug=%@ autoplay=%@ mode=%ld\n",
            [d objectForKey:FDEnabledKey] ?: @"<unset>",
            [d objectForKey:FDDebugKey] ?: @"<unset>",
            [d objectForKey:FDAutoplayKey] ?: @"<unset>",
            (long)FDNum(FDModeKey, 5)];
        [out appendFormat:@"hooks autoplay=%d%d%d%d observeIM=%d luckyBox=%d\n",
            gAutoPlay1, gAutoPlay2, gAutoPlay3, gAutoPlay4, gObserveIM, gLuckyBox];
        [out appendFormat:@"classes luckyBoxMgr=%@ autoPlayMgr=%@\n",
            NSClassFromString(@"IESLiveLuckyBoxServiceManager") ? @"FOUND" : @"MISSING",
            NSClassFromString(@"AWEFeedIPhoneAutoPlayManager") ? @"FOUND" : @"MISSING"];
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *file = [paths.firstObject stringByAppendingPathComponent:@"fudai_boot.txt"];
        [out writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[FuDai] boot marker -> %@", file);
    }
}

static void FDInitHooks(void) {
    if (!gObserveIM && NSClassFromString(@"AWEIMDouyinRedPacketComponent")) {
        gObserveIM = YES; %init(GObserveIM);
    }
    Class lbm = NSClassFromString(@"IESLiveLuckyBoxServiceManager");
    if (!gLuckyBox && lbm && [lbm instancesRespondToSelector:@selector(messageReceived:)]) {
        gLuckyBox = YES; %init(GLuckyBoxManager);
        FDLog(@"hooked IESLiveLuckyBoxServiceManager");
    }
    if (!gAutoPlay1 && NSClassFromString(@"AWEAwemeDetailTableViewController")) {
        gAutoPlay1 = YES; %init(GAutoPlay1);
    }
    if (!gAutoPlay2 && NSClassFromString(@"AWEAwemeDetailContainerPlayControlConfig")) {
        gAutoPlay2 = YES; %init(GAutoPlay2);
    }
    if (!gAutoPlay3 && NSClassFromString(@"AWEFeedIPhoneAutoPlayManager")) {
        gAutoPlay3 = YES; %init(GAutoPlay3);
    }
    if (!gAutoPlay4 && NSClassFromString(@"AWEFeedModuleService")) {
        gAutoPlay4 = YES; %init(GAutoPlay4);
    }
    if ((gAutoPlay1 || gAutoPlay2 || gAutoPlay3 || gAutoPlay4) && !gAutoPlayLogged) {
        gAutoPlayLogged = YES;
        FDLog(@"autoplay guard hooks installed (%d%d%d%d)", gAutoPlay1, gAutoPlay2, gAutoPlay3, gAutoPlay4);
    }
}

%ctor {
    @autoreleasepool {
        // ★ 多副本去重：克隆抖音里同时存在 内嵌副本(Frameworks) 与 substrate注入副本(/var/jb)，
        //   两份 %ctor 都会跑 → 双引擎打架。只让最先加载的那份初始化。
        @try {
            Dl_info info;
            if (dladdr((void *)&FDInitHooks, &info) && info.dli_fname) {
                const char *selfPath = info.dli_fname;
                BOOL selfIsFirst = NO;
                uint32_t n = _dyld_image_count();
                for (uint32_t i = 0; i < n; i++) {
                    const char *p = _dyld_get_image_name(i);
                    if (p && strstr(p, "FuDai.dylib")) {
                        selfIsFirst = (strcmp(p, selfPath) == 0);
                        break;
                    }
                }
                if (!selfIsFirst) {
                    NSLog(@"[FuDai] duplicate copy detected at %s, skipping init", selfPath);
                    return;
                }
            }
        } @catch (NSException *e) { }
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            FDEnabledKey: @NO,
            FDDebugKey: @NO,
            FDAutoplayKey: @YES,
            FDModeKey: @5,
            FDGrabMinKey: @60,
            FDBrowseMinKey: @10,
            FDRestMinKey: @0,
            FDDiaAttendKey: @50,
            FDDiaRewardKey: @5,
            FDDiaLimitMinKey: @4,
            FDSupAttendKey: @100,
            FDSupLimitMinKey: @15,
            FDMinSuperKey: @50,
            FDMaxSuperKey: @99999,
            FDMaxRoomKey: @200000,
            FDFilterRoomKey: @NO,
            FDWaitRoomKey: @5,
            FDWatchSecKey: @5,
            FDLiveSchemeKey: @"snssdk1128://live",
            FDMaxSwitchKey: @60,
            FDLikeRateKey: @30,
            FDLikeMinKey: @5,
            FDLikeMaxKey: @50,
            FDCmtRateKey: @0,
            FDCommentsKey: @"主播太帅了/真好/太完美了/优秀/Perfect!",
            FDSearchKey: @"带货直播间",
            FDAttendModeKey: @6,
            FDFansTeamKey: @YES,
            FDFansYuanKey: @2000
        }];
        NSLog(@"[FuDai] 0.7.0 loaded bundle=%@", NSBundle.mainBundle.bundleIdentifier);

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
