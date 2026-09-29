# 思文加加（siwenjiajia / SJJ）抖音优化插件 28.52 深度逆向分析报告

> 分析对象：
> - **主目标**：`analysis/payload/var/jb/Library/MobileSubstrate/DynamicLibraries/siwenjiajia.dylib`（10,767,584 字节，官方 28.52 版）
> - **参考对比**：`dist/sjj_embedded.dylib`（10,467,776 字节，用户克隆抖音内实际运行的版本）
> - 过滤目标：`com.ss.iphone.ugc.Aweme`（抖音），rootless 越狱环境（LC_RPATH 含 `/var/jb/Library/Frameworks`）
>
> 分析方式：自研 Python Mach-O 解析器（`docs/re-scripts/sjj_macho.py`、`xref.py`、`explain.py`、`hooks.py`、`dump_all.py`）+ capstone 5.0.7 全量反汇编（__text 段 164 万条指令），未修改任何二进制。
>
> **重要更正**：两个 dylib 实际都是 **thin arm64 Mach-O**（cputype `0x0100000C`，无 FAT 头、无 arm64e slice），此前"10.7MB FAT 含 arm64+arm64e"的说法不成立。代码内部使用 arm64e 风格的 PAC 指令（pacibsp/braa/paciza）与 **DYLD_CHAINED_PTR_ARM64E 链式重定位**（pointer_format=1），属于 arm64 上带 PAC 的普通二进制。

---

## 1. 文件结构概览

### 1.1 基本参数（两者几乎一致）

| 项目 | 28.52 官方版 | embedded 版 |
|---|---|---|
| 文件类型 | MH_DYLIB (thin arm64) | 同左 |
| __TEXT vm size | 0x928000 | 0x8e8000 |
| __text 大小 | 0x6423bc（起始 0x4000） | 0x613f74 |
| 函数数量（LC_FUNCTION_STARTS） | 28,035 | 27,036 |
| OC 类数量 | **133**（实例方法 3,741 + 类方法 236） | **115**（3,497 + 234） |
| selrefs / classrefs | 6,417 / 357 | 6,215 / 339 |
| 导入符号（chained fixups imports） | 818 | 815 |
| 配置键（sjj_/DYYY_/siwenjiajia_ 前缀） | 399 | 382 |
| 链接的 Substrate | **无**（不链接 libsubstrate，无 MSHook* 字符串/符号） | 同左 |

### 1.2 加固/混淆痕迹（反逆向处理）

1. **节名混淆**：除 `__objc_*`、`__gcc_except_tab`、`__unwind_info` 等必须可识别的节外，`__text`、`__stubs`、`__objc_stubs`、`__cstring`、`__got`、`__cfstring` 等节的 16 字节节名被替换为随机字节（如 `\x8d\xfc\xb4\xce...`），节 flags 全部清零。
2. **自定义节**：`__DATA` 中存在 `__sjjprot`（0x32B）、`__sjjpkga/b/c`（各 0x300B）——插件自身的保护/校验数据；末尾有一个 0x14DCE8 的大节（大部分为 bss 式运行时全局区，**所有功能开关字节、orig IMP 缓存表都放在这里**，如 `0xA15AA8`、`0xA18000` 表）。
3. **PAC（指针认证）**：所有函数 `pacibsp` 开头；调用导入函数用 `braa/braaz`；取 hook 函数地址用 `adrp+add` 到 `x16` 后 `paciza` 签名（A 键）再传入。
4. **链式重定位**：`LC_DYLD_CHAINED_FIXUPS`，pointer_format = 1（DYLD_CHAINED_PTR_ARM64E）：plain rebase（target 43bit）、bind（ordinal 16bit）、auth_rebase（target 32bit+diversity）。__DATA 内所有内部指针在文件里都是"编码态"（如 `0x0008000000A10C50`），静态分析必须先解码。
5. **方法名间接存储**：自身类采用 small method list（entsize `0x8000000C`，12 字节项），name 字段为相对偏移指向 **__objc_selrefs 槽**（selref 间接，pointer-kind），而非直接指向 __objc_methname。
6. **未加密**：`__objc_methname`（8,067 条）、`__objc_classname`、`__cstring`（3.1 万条）、`__ustring`（7,630 条 UTF-16 UI 文案）全部明文。类名（SJJ*）、方法名、选择器、UserDefaults 键名、中文设置文案均可直接检索。

### 1.3 关键节布局（28.52 官方版，embedded 地址不同）

| 地址 | 大小 | 内容 |
|---|---|---|
| 0x4000 | 0x6423bc | `__text` 代码 |
| 0x6463bc | 0x16a0 | `__auth_stubs`（365 个导入桩，16B/项：adrp x17 / add / ldr x16 / braa） |
| 0x647a60 | 0x1fc00 | `__objc_stubs`（4,048 个 msgSend 桩，32B/项：加载 selref→x1，跳 objc_msgSend） |
| 0x667710 | 0xd2cc | `__objc_methlist`（small method lists） |
| 0x808453 | 0x31131 | `__objc_methname` |
| 0x83e4b6 | 0x287c0 | `__ustring`（UTF-16 设置文案） |
| 0x928000 / 0x9ebf40 | — / 0xb68 | `__DATA_CONST` 区 / `__auth_got`（365 槽） |
| 0x93c1f8 | 0x7b7e0 | `__cfstring`（常量字符串对象，含全部设置文案/键名） |
| 0xA026c0 | 0xc888 | `__objc_selrefs` |
| 0xA0ef50 | 0xb28 | `__objc_classrefs` |
| 0xA10c50 | 0x2990 | `__objc_data`（类对象） |
| 0xA15980+ | 0x14dce8 | 运行时全局区（开关字节、orig IMP 表、缓存） |

---

## 2. Hook 机制（总体架构）

### 2.1 不使用 Substrate，纯 ObjC Runtime 替换

导入表里**没有** `MSHookMessageEx` / `MSHookFunction`，也没有任何 substrate 字符串。Hook 完全通过：

```
class_getInstanceMethod(cls, sel)
method_getImplementation(m)            → origIMP（缓存到全局表）
class_addMethod(cls, sel, newImp, types)   （防"方法不存在"）
method_setImplementation(m, newImp)    → 返回值即旧 IMP
```

通用 hook 辅助函数（约定 `(x0=Class, x1=SEL, x2=newIMP, x3=IMP*origOut)`）：

- **`sub_0x2E8F00`（0x2e8f00）**：主 hooker。逻辑：取 method → 取 orig → 若 orig==newImp 跳过 → class_addMethod → method_setImplementation → `*origOut = 旧IMP`。
- `sub_0x2D9D80`、`sub_0x2E4A18`、`sub_0x2E4A00`、`sub_0x2D7FDC` 等：**寄存器搬运 thunk**（如 `mov x2,x16; mov x0,x26; ret`），仅用于压缩安装代码体积，最终都落入 0x2e8f00。
- 全镜像共有 **1,832 处对 0x2e8f00 的调用**（embedded 1,863 处，21 个 helper 变体），另有少量直接调用 `method_setImplementation` 的场景。

### 2.2 加载链

```
SJJVideoStatsFakeBootstrap  +load   (imp 0x4AA154)
  └─ 0x4A9EB4：os_unfair_lock 保护的 once 标记
       └─ dyld_register_func_for_add_image(0x4AA0E4)   ← 等宿主镜像就绪
          └─ …（autoreleasepool 包装 sub_0x145648）
               └─ sub_0x145680 = 主 hook 安装器（~16KB，安装绝大多数 hook）
               └─ sub_0x4E7F04 = 信息流/广告过滤模块安装器（见 §4.3）
               └─ 其它功能模块安装器（smooth swipe 等，见 §5）
```

### 2.3 每个功能 = 一个"开关字节 + 门卫式 hook"

插件把每个功能的开关缓存在运行时全局字节里（主开关 `0xA15AA8`、自动连播 `0xA15B35`、纯净模式 `0xA15B91`……集中在一个 bss 式页面）。Hook 函数头部固定模式：

```asm
adrp  x8, #0xA15000
ldrb  w9, [x8, #0xAA8]      ; 主开关
tbz   w9, #0, L_orig
ldrb  w8, [x8, #0xB35]      ; 运行时开关
tbz   w8, #0, L_orig
mov   w0, #1                ; 强制返回 YES
ret
L_orig:
adrp  x8, #0xA18000
ldr   x2, [x8, #0x720]      ; 缓存的 orig IMP（PAC 脱签后尾调）
braaz x2
```

orig IMP 统一缓存在 **0xA18000 起的表**（每 hook 8 字节：0xA18720/0xA18728/…），由安装器在 hook 时写入。

---

## 3. 类清单

### 3.1 前缀分布（28.52 共 133 类）

| 前缀 | 数量 | 说明 |
|---|---|---|
| `SJJ*` | 115 | 插件主体（面板、悬浮胶囊、下载、TTS、相机、语音包……） |
| `SWJ*` / `SWJJ*` | 6+2 | 旧版本遗留前缀：`SWJManager`（媒体下载管理，58 实例方法+41 类方法：URLSession 下载队列、LivePhoto 合成、GIF/HEIC 转换、批量下载进度）、`SWJUtils`（36 类方法）、`SWJToast`（36 方法，Toast UI）、`SWJJCommentPanelFrameState/LayoutState`（28.52 新增评论区布局状态） |
| `AWE*`（真·抖音类） | 6 | 被 hook 的宿主类在本镜像内的引用（`AWEFeedTableViewController` 等，仅 classref，无实现） |
| `AWECA*` | 4 | **插件自有类伪装成抖音前缀**：`AWECAAIReplyController`（64 方法）、`AWECAAIReplySettingsController`（157）、`AWECAAIReplyService`（64 类方法，OpenAI 接口）、`AWECAIMSwipeReplyProxy`、`AWECAIMQuickActionDismissProxy`、`AWECAUtils`（26 类方法）——AI 评论/回复功能 |
| `siwenjiajia*` | 2 | `siwenjiajiaEntryHandler`（**134 个实例方法**，主入口/动作分发：视频长按菜单、悬浮胶囊动作 handleVideoPopupActionTag:、侧边栏 sideDock*）、`siwenjiajiaPanel`（**558 个实例方法**，设置面板 UI） |
| 其它 | 4 | `AwemeXConfigManager`（13，配置缓存单例）、`AWMSafeDispatchTimer`（16，安全定时器）、`CityManager`（6）、`MemUi`（1 类方法） |

### 3.2 核心类方法要点（与"自动播放/自动滑动"直接相关）

```
SJJFeedSmoothSwipePanDriver            # 顺滑滑动驱动
  - initWithScrollView:      imp 0x4B3954
  - sjj_handlePan:           imp 0x4B39D0   # 核心：接管 scrollView.panGestureRecognizer
  - scrollView / setScrollView:
SJJFeedSmoothSwipeWeakScrollViewBox    # scrollView 弱引用盒
  - scrollView / setScrollView:
SJJHiFloatingButton                    # 悬浮胶囊按钮（含"自动连播"图标）
  - sjj_touchUp:             imp 0x3AAD2C   # 触摸抬起：读 consumeNextTap / setConsumeNextTap:
  - sjj_handlePan:           imp 0x3AB0D8   # 拖动结束置 consumeNextTap（防止拖动误触发点击）
  - restoreFromEdgeHidden    imp 0x3AA45C   # 从边缘隐藏恢复时复位 consumeNextTap
  - reloadPresentationTimers imp 0x3A9AD4   # dimTimer / edgeHideTimer 定时器
SJJSideDockWakeSlideSelectSession      # 侧边栏"唤醒滑动"会话（reveal DisplayLink、触感反馈）
SJJWeakDisplayLinkProxy                # CADisplayLink 弱代理（防循环引用）
  - displayLinkDidFire:      imp 0xE028
SJJVideoProgressSyntheticGesture       # 合成手势（进度条用）
```

> `consumeNextTap` / `setConsumeNextTap:` 是**插件悬浮按钮自己的手势状态**（BOOL 属性）：`sjj_handlePan:` 结束时 `setConsumeNextTap:YES`，随后的 `sjj_touchUp:` 读到 YES 就吞掉本次抬起（避免拖拽结束被当作点击），并写回 NO。它不属于自动播放链路。

---

## 4. ★ 自动播放（自动连播/自动刷视频）完整实现链路 ★

UI 文案证据（__ustring，UTF-16）：

- 设置项：**「启用自动播放」**（0x83FDD4）
- 说明：*「这里只是总开关，开启后不会立即连播。回到视频页，点击右侧悬浮胶囊里的『自动连播』图标，才会真正开启或关闭自动连播。」*（0x840CD8）
- 入口说明（0x843B2C）：三个入口共用同一开关状态——① 视频页右侧悬浮胶囊的「自动连播」图标（开总开关后自动出现）；②「双击快捷操作」勾选；③ 视频长按菜单→菜单内容勾选。
- Toast：`自动播放已开启`（0x8544A4）/ `自动播放已关闭`（0x8544B4）/ `请先在插件面板开启「启用自动播放」`（0x854480）。

### 4.1 配置与状态层

| 键（NSUserDefaults） | 作用 | 对应内存 |
|---|---|---|
| `sjj_auto_play_feature_enabled_v1` | **总开关**（面板「启用自动播放」） | 全局字节 **0xA15AA8** |
| `sjj_auto_play_active_v1` | **运行时开关**（胶囊图标切换） | 全局字节 **0xA15B35** |
| `"D" + "YYYisEnableAutoPlay"` = **`DYYYisEnableAutoPlay`** | 同上（兼容键，两键同时写） | — |

> 键名 `DYYYisEnableAutoPlay` 由两个 CFString 拼接（`stringByAppendingString`，@"D"+@"YYYisEnableAutoPlay"，见 0x12A904），证明此功能**移植自知名插件 DYYY**；`sjj_auto_play_active_v1` 是思文加加自己的键。两个开关均为 BOOL。

**开关写入函数 `sub_0x12A8A8(BOOL on, BOOL showToast)`（imp 0x12A8A8）**：

```
state = on & [0xA15AA8]          ; w21 = w0 & masterByte
strb  w21, [0xA15B35]            ; 写运行时字节
[自定义defaults setBool:state forKey:@"sjj_auto_play_active_v1"]   (0x12C71C)
[standardUserDefaults setBool:state forKey:@"DYYYisEnableAutoPlay"] (拼接键)
sub_0x6BA4()                     ; 通知其它模块刷新
if (showToast) SWJToast 风格 showToast:@(state? @"自动播放已开启" : @"自动播放已关闭") duration:…
```

**切换入口**（调用 0x12A8A8 或其包装 0x3772C）：

| 入口 | 函数 |
|---|---|
| 悬浮胶囊「自动连播」图标 | `siwenjiajiaEntryHandler -handleVideoPopupActionTag:` → 0x3772C |
| 侧边栏自定义动作 | `siwenjiajiaEntryHandler -sideDockCustomActionTap:` → 0x3772C |
| 设置面板开关 | `siwenjiajiaPanel -swChange:`（读写 `sjj_auto_play_feature_enabled_v1` 与 `sjj_auto_play_active_v1` 两个键，0x121E78/0x121EA4，并调 0x12A8A8 三处） |
| 启动恢复 | `sub_0x7600`（启动时读两个键 → 恢复 0xA15AA8/0xA15B35）；`sub_0x275548`（状态同步） |

`0x3772C`（图标点击包装）：主开关关闭时 Toast「请先在插件面板开启『启用自动播放』」；否则 `0x12A8A8(~state)` 翻转。

### 4.2 核心：强制宿主"自动播放判定"为 YES（门卫 hook 家族）

安装器 `sub_0x145680` 在启动时安装以下 5 个 hook（全部经 0x2E8F00，orig IMP 缓存于 0xA18000 表）：

| # | 宿主类 | 被替换方法 | hook IMP | orig 缓存 | 生效时行为 |
|---|---|---|---|---|---|
| 1 | `AWEAwemeDetailTableViewController` | `- hasIphoneAutoPlaySwitch` | 0x29B9D8 | 0xA18720 | 返回 YES |
| 2 | `AWEAwemeDetailContainerPlayControlConfig` | `- enableUserProfilePostAutoPlay` | 0x29BDE4 | 0xA18748 | 返回 YES |
| 3 | `AWEFeedIPhoneAutoPlayManager` | `- isAutoPlayOpen` | 0x29BE10 | 0xA18750 | 返回 YES |
| 4 | `AWEFeedIPhoneAutoPlayManager` | `- getFeedIphoneAutoPlayState` | 0x29BE3C | 0xA18758 | 返回 1 |
| 5 | `AWEFeedModuleService` | `- getFeedIphoneAutoPlayState` | 0x29BE68 | 0xA18760 | 返回 1 |

每个 hook 的实现（以 0x29B9D8 为例，其余同构）：

```c
BOOL hook(...) {
    if (*(uint8_t*)0xA15AA8 /*总开关*/ && *(uint8_t*)0xA15B35 /*自动连播运行开关*/)
        return 1;                    // 强制"自动播放已开启"
    return orig(self, _cmd, ...);    // 否则透传原实现（braaz 脱签尾调）
}
```

**链路结论**：插件不自己实现"播完切下一个"的定时器/播放进度监听，而是**让抖音自带的自动播放引擎误以为"自动连播"已开启**——抖音信息流/详情页/主页作品的原生自动连播逻辑（由 `AWEFeedIPhoneAutoPlayManager`、`AWEFeedModuleService` 驱动）在判定处读到 YES，于是原生完成自动切播。这就是整条自动播放链路的**推进器**：没有自建计时器，没有模拟拖拽，没有 KVC 触发播放。

伴随 hook（同一安装器区域，属于同族状态控制）：

- `AWEFeedRootViewController` 两个方法 → 纯透传 trampoline（0x29BE94/0x29BEA0，orig@0xA18768/0xA18770），为运行时二次 patch 预留；
- `AFDPureModePageContainerViewController` 出现/消失 hook（0x29BEE4/0x29BF1C）→ 写全局字节 **0xA15B91**（纯净模式进入/退出标志）；
- `AWEIMSkylightListView` → 透传（0x29BF50）；
- `AWEPlayInteractionViewController` 多个方法（0x29BF5C/0x29BFEC/`setContext:`/`onVideoPlayerViewDoubleClicked:` 等）→ 互动层配合。

### 4.3 附加推进器：广告/直播自动跳过（真正调用 scrollToNextVideo 的地方）

安装器 **`sub_0x4E7F04`**（信息流过滤模块）安装：

| 宿主类 | 方法 | hook IMP | 说明 |
|---|---|---|---|
| `AWEFeedTableViewController` | `- displayCaptionInfoWithNextModel:` | 0x4E82B8 | 调度重试跳过 |
| `AWEFeedTableViewController` | `- playVideo:` | 0x4E8638 | 播放时判定广告/直播→跳过 |
| `AWEListDataController` | `setDataSource:` / `dataSource` / `setFilteredDataSource:` / `filteredDataSource` | 0x4E88E4 / 0x4E89AC / 0x4E8A74 / … | 数据源级广告过滤 |
| `AWEMixVideoListDataController` / `AWEMixVideoDetailPlayListDataController` / `AWEMixVideoRelatedListDataController` | 同上（set/dataSource 系列） | … | 混排流同样过滤 |
| `AWEHotListDataController` | `transferAwemeListIfNeededWithArray:isInitFetch:` | … | 列表装入前剔除广告模型 |
| `AWEAwemeModel` | `initWithDictionary:error:` / `init` / `setAdLinkType:` | … | 打广告标 |
| `TTAdSplashModel` / `BDASplashControllerView` / `AWEOriginalAdModel` / `AWEGeneralSearchModel` / `AwemeAdManager(- showAd)` / `AWEAwesomeSplashFeedCellOldAccessoryView(- ddExtraView)` | … | … | 开屏/搜索/通用广告抑制 |

开关（均 `boolForKey:`，见 0x4E7DE0）：`sjj_ad_filter_enabled_v1`、`sjj_feed_ad_filter_enabled_v1`、`sjj_live_preview_auto_skip_enabled_v1`、`sjj_search_ad_filter_enabled_v1`、`sjj_splash_ad_filter_enabled_v1`、`sjj_chapter_ad_skip_enabled`。

**`playVideo:` hook（0x4E8638）精确逻辑**（反汇编直译）：

```objc
// x0=self(AWEFeedTableViewController) —— 先放行原调用
orig_playVideo(self, sel, model);                       // orig IMP @0xB60410

id aweme   = [self valueForKey:@"currentAweme"];        // 安全 KVC(try/catch) 0x4E9920
if (!adFilterEnabled() || !topVcAllowed()) return;      // 0x4EA4CC / 0x4EA50C
id parent  = [self valueForKey:@"parentViewController"];
for (NSString *clsName in <全局类名白名单数组>)          // 含 @"AWEFeedRootViewController"
    if ([parent isKindOfClass:NSClassFromString(clsName)]) goto do_skip;
return;
do_skip:
    SEL scrollToNext = NSSelectorFromString(@"scrollToNextVideo");
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:scrollToNext object:nil];
    NSString *itemID = [aweme valueForKey:@"itemID"];
    if (itemID && [self respondsToSelector:@selector(onAwemeDeleted:isDislike:silentlyDelete:)])
        [self onAwemeDeleted:itemID isDislike:NO silentlyDelete:YES];  // 让抖音"静默删除"该条(广告)并原生切下一条
    if ([self respondsToSelector:scrollToNext])
        [self scrollToNextVideo];                        // 双保险：主动滑到下一个
```

**`displayCaptionInfoWithNextModel:` hook（0x4E82B8）**：取消已排队的 `scrollToNextVideo` perform → 递增关联对象重试计数（assoc key 0xB6003F0，NSNumber）→ 校验 `UIApplication.applicationState==Active` → 用 KVC 键 `liveStreamURL` / `room` 判断当前是否直播（是则不跳）→ `dispatch_after(5.0s)` 调度重试块 **0x4EA0D4**（块内再次校验：重试代际号一致、总开关 `sjj_live_preview_auto_skip_enabled_v1`、app 前台、self 是 UIViewController 且 `isViewLoaded && view.window != nil`、`currentVCIsActive`，全部通过才再次执行跳过流程）。

> 因此 `scrollToNextVideo` 是**抖音侧已有的方法**（`AWEFeedTableViewController`/`AWEFeedPagingManager` 一族），插件通过 `NSSelectorFromString(@"scrollToNextVideo")` + `respondsToSelector:` 动态调用——字符串 `scrollToNextVideo`（0x7F9C0C）只在这个模块出现；`YYYisEnableAutoPlay` 字符串则是 DYYY 兼容键的一半。

### 4.4 顺滑滑动（FeedSmoothSwipe）—— 手势优化，不是自动播放

安装流程（0x4B99F4，被 scrollView 相关 hook 触发）：

1. 对 feed 的 UIScrollView：把原 `isPagingEnabled` / `decelerationRate` / `isDirectionalLockEnabled` 存入关联对象（key 0xB5F96E/96F/970）；
2. 强制 `setPagingEnabled:`（按需）、`setDecelerationRate:`（常量 0.0078125=2^-7，快速减速）、`setDirectionalLockEnabled:YES`；
3. 从 `panGestureRecognizer` 上 `removeTarget:action:` 移除旧驱动（sel `sjj_handlePan:`），创建/复用 `SJJFeedSmoothSwipePanDriver`（classref 0xA0F850）并挂回 `sjj_handlePan:`；
4. `sjj_handlePan:`（0x4B39D0）：`state==Began` 时记录起始 contentOffset；`Changed/Ended` 时读 `velocityInView:` + `translationInView:`，按内容页高（contentSize/bounds）与 0x77EA28 处静态 double 表（1/3 插值系数、0.333…、0.999… 等）做**自定义插值曲线驱动 contentOffset**，实现"跟手+惯性"的整页顺滑切换；
5. 设置键：`sjj_feed_smooth_swipe_enabled_v1`、`sjj_feed_smooth_swipe_speed_mode_v1`、`sjj_feed_smooth_swipe_custom_duration_v1`、`sjj_feed_smooth_swipe_background_mode_v1` / `_color_hex_v1` / `_custom_background_image_data_v1`、`sjj_feed_smooth_swipe_corner_enabled_v1` / `_corner_radius_v1`；面板入口 `siwenjiajiaPanel -openFeedSmoothSwipeSettingsPage` / `-configureFeedSmoothSwipeSpeed` / `-promptFeedSmoothSwipeCustomSpeed` / `-applyFeedSmoothSwipeBackgroundImage:` 等。

### 4.5 复刻"自动连播"所需的最小实现清单（给工程师）

1. **两极开关**（建议照抄）：
   - 总开关 BOOL → `NSUserDefaults("sjj_auto_play_feature_enabled_v1")`
   - 运行开关 BOOL → `NSUserDefaults("sjj_auto_play_active_v1")`（可再加 `DYYYisEnableAutoPlay` 兼容）
   - 全局缓存两个字节；生效条件 = 总开 && 运行开。
2. **5 个强制 hook**（method_setImplementation，orig 保存以便关闭时透传）：

```objc
// 全部 BOOL 返回；hook 体：if (总开 && 运行开) return YES; return orig(...);
[AWEAwemeDetailTableViewController        hook:@selector(hasIphoneAutoPlaySwitch)];
[AWEAwemeDetailContainerPlayControlConfig hook:@selector(enableUserProfilePostAutoPlay)];
[AWEFeedIPhoneAutoPlayManager             hook:@selector(isAutoPlayOpen)];
[AWEFeedIPhoneAutoPlayManager             hook:@selector(getFeedIphoneAutoPlayState)];
[AWEFeedModuleService                     hook:@selector(getFeedIphoneAutoPlayState)];
```
   类不存在时逐个判空（`objc_getClass` 返回 NULL 则跳过），新版本抖音类名可能变化。
3. **UI**：面板总开关 + 悬浮胶囊图标（点击翻转运行开关并 Toast）。
4. 可选（广告跳过增强，见 §4.3）：hook `AWEFeedTableViewController playVideo:`，命中广告模型后 `onAwemeDeleted:isDislike:NO silentlyDelete:YES` + `scrollToNextVideo`（均 `NSSelectorFromString` + `respondsToSelector:` 防御），配 5s `dispatch_after` 重试与 `view.window`/前台校验。
5. 无需：定时器、播放进度监听、模拟 scrollView 拖拽——推进由抖音原生自动连播引擎完成。

---

## 5. Hook 安装器与 hook 总量

- 主安装器 `sub_0x145680`（0x145680–0x153xxx 区段），以 `objc_getClass("类名字符串")` + selref + `paciza 签名后的 hook IMP` + orig 全局地址为一组，每组调用 0x2E8F00；字符串均明文（如 `"AWEAwemeDetailTableViewController"`、`"AWEFeedIPhoneAutoPlayManager"`、`"AWECommentInputViewController"`、`"TTHttpRequestChromium"`、`"AVPlayerItem"`、`"IESLiveStreamPlayerVideoAudioEffectPlugin"`…）。
- 抽样确认的 hook 类（共 59+ 类，含清屏、隐藏元素、去广告、VoIP 拦截 `__checkIsValidForReceivedVoip:`、VPN 检测 `isVPNActive`、HDR `hdrAutomaticIdentification`、评论区、TabBar、直播音频等）：
  - 方法替换热点：`layoutSubviews`(11)、`didMoveToWindow`(11)、`didMoveToSuperview`(9)、`viewDidLayoutSubviews`(9)、`viewDidLoad`(8)、`viewDidDisappear:`(7) 等。
- 独立模块安装器：`sub_0x4E7F04`（信息流广告过滤，§4.3）；smooth-swipe/scrollview 系（0x4B41C8 等，§4.4）。
- **版本对比**：embedded 与 28.52 的自动播放 hook 家族、广告过滤模块、smooth swipe **完全一致**（同名同构，仅地址不同）。

---

## 6. 配置键体系（UserDefaults）

存储位置：`Library/Preferences/com.siwenjiajia.tweak.plist`（主）、`.ai.plist`、`.mirror.plist`、`.authguard.plist`、`siwenjiajia_switches.plist`、`siwenjiajia_plugin_config.json`（导入导出）。命名规律：新键 `sjj_<feature>[_<detail>]_v1`，遗留 `siwenjiajia_*`，兼容 `DYYY*`。共 399 个（embedded 382 个，全部为 28.52 子集）。

**自动播放/滑动相关键**：

| 键 | 含义 |
|---|---|
| `sjj_auto_play_feature_enabled_v1` | 自动播放总开关（面板） |
| `sjj_auto_play_active_v1` | 自动连播运行开关（胶囊图标） |
| `DYYYisEnableAutoPlay` | 同上（DYYY 兼容键） |
| `sjj_ad_filter_enabled_v1` / `sjj_feed_ad_filter_enabled_v1` / `sjj_search_ad_filter_enabled_v1` / `sjj_splash_ad_filter_enabled_v1` | 广告过滤（信息流/搜索/开屏） |
| `sjj_live_preview_auto_skip_enabled_v1` | 直播预览自动跳过 |
| `sjj_chapter_ad_skip_enabled` | 图集章节广告跳过 |
| `sjj_video_long_press_hide_auto_play_v1` | 长按菜单隐藏"自动播放"项 |
| `sjj_feed_smooth_swipe_enabled_v1` | 顺滑滑动总开关 |
| `sjj_feed_smooth_swipe_speed_mode_v1` / `_custom_duration_v1` | 滑动速度模式/自定义时长 |
| `sjj_feed_smooth_swipe_background_mode_v1` / `_color_hex_v1` / `_custom_background_image_data_v1` | 过渡背景 |
| `sjj_feed_smooth_swipe_corner_enabled_v1` / `_corner_radius_v1` | 过渡圆角 |
| `sjj_ios26_glass_scope_wake_slide_enabled_v1` | iOS26 玻璃风格侧边栏唤醒滑动 |
| `siwenjiajia_panel_theme_mode` | 面板主题 |
| `siwenjiajia_last_known_*`（douyin_id/nickname/avatar_url/phone_number 及 `_source`/`_time`） | 账号信息缓存 |

设置项状态读写模式：面板开关 tag（数字）→ `siwenjiajiaPanel -featureSwitchStateForTag:known:` / `-swChange:` → 全局字节 + `setBool:forKey:`；启动时 `sub_0x7600`（约 0x7600–0xC97C，巨型初始化）批量恢复到全局字节页。

---

## 7. UI 文案与功能命名（__ustring 摘录）

功能项（节选）：启用自动播放、AI自动点赞/自动评论/自动私信、滑动新视频自动直发（Beta）、启用摇一摇隐藏/唤醒、经验板块自动播放背景音、滑动快捷回复、快捷切换账号、AI机器人自动筛选视频、滑动视频过渡动画、开启后到视频页右侧胶囊点「自动连播」图标才生效、隐藏自动连播、切换当前自动连播状态……（完整 7,630 条见 `docs/re-scripts/ustring_official.txt`）。

---

## 8. 28.52 官方版 vs embedded 版差异结论

1. **类**：embedded（115 类）是 28.52（133 类）的**严格子集**；28.52 新增 18 类，全部是 UI/体验类：
   `SJJGlassExperienceListState`、`SJJGlassExperienceScrollTopButton`、`SJJGlassRoundKeyHitButton`、`SJJHighRefresh*`（6 类：高刷 FPS 胶囊/配置覆盖窗/滚动联动）、`SJJHomeTopGlass*`（5 类：首页顶部玻璃动作位）、`SJJVideoLongPressLabelState`、`SWJJCommentPanelFrameState`、`SWJJCommentPanelLayoutState`。
2. **方法差异**仅 3 个共享类：
   - `AWECAAIReplyService` +`defaultImageModelName`/`openAIChatModels`（OpenAI 模型选择）
   - `AWECAAIReplySettingsController` +`pickOpenAIChatModel:`
   - `siwenjiajiaPanel` +8 个评论区背景/圆角/玻璃 TabBar 设置方法
3. **配置键**：28.52 多 17 个（399 vs 382），均为新增 UI 功能键；**自动播放/广告过滤/顺滑滑动键集完全相同**。
4. **自动播放实现相同**：embedded 里同样存在 `DYYYisEnableAutoPlay` 拼接键、5 个门卫 hook、`playVideo:`→`onAwemeDeleted`/`scrollToNextVideo` 逻辑（代码同源，仅基址不同）。**用户克隆抖音里跑的旧版与 28.52 的自动播放是同一实现。**

---

## 9. 复用资产（本项目 docs/re-scripts/ 下）

| 文件 | 用途 |
|---|---|
| `sjj_macho.py` | Mach-O/ARM64E 链式重定位/OC 类与 small method list 解析库 |
| `dump_all.py` / `dump_official.json` / `dump_embedded.json` | 全量类/方法/ivar/selref/classref/导入表转储 |
| `xref.py` | capstone 全量扫描（adrp/add/ldr/bl 跟踪、__objc_stubs→sel、__auth_stubs→符号） |
| `explain.py` | 单函数注解反汇编（字符串/选择器/类/调用解析） |
| `hooks.py` / `hooks_official.json` / `hooks_embedded.json` | 通用 hooker 调用点与参数恢复 |
| `q_official.txt` / `q_embedded.txt` | 关键选择器交叉引用报告 |
| `ustring_official.txt` | 7,630 条 UTF-16 设置文案 |
| `cstrings_official.txt` / `keys_official.txt` / `keys_all.txt` / `cfgkeys.txt` | 明文字符串与配置键 |

> 后续抖音版本升级导致类名/方法名变化时，重点核对 §4.2 表中 5 个宿主类与 §4.3 的 `playVideo:` / `onAwemeDeleted:isDislike:silentlyDelete:` / `scrollToNextVideo` 是否仍存在（均应使用 `objc_getClass`/`NSSelectorFromString`/`respondsToSelector:` 做运行时防御——本插件正是这样做的）。
