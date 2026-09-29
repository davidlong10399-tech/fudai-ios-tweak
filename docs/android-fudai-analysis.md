# 福袋助手（com.android.greaderex v1.700）深度逆向分析

> 分析目的：为 iOS 越狱插件完整复刻其"全自动循环"（逛推荐页 → 发现福袋直播间 → 进房 → 抢福袋 → 退出 → 继续）。
> 分析方式：静态逆向。manifest 用 apkutils2 解析，DEX 用 androguard 3.3.5 反编译（DAD），RedbagSetActivity 等反编译失败的关键类用 smali 字节码人工核对。
> 本文所有 viewId、文本匹配串、坐标、毫秒数、默认值均直接取自反编译产物，可信赖度：高（核心循环已逐方法核对）。

---

## 1. APK 概览

| 项目 | 值 |
|---|---|
| 包名 | `com.android.greaderex`（App 显示名：**福多多**） |
| versionName / versionCode | 1.700 / 1 |
| minSdk / targetSdk | 24 / 33（compile 34） |
| 目标 App（queries） | `com.ss.android.ugc.aweme.lite`（抖音极速版）、`com.ss.android.ugc.aweme`（抖音）、`com.kuaishou.nebula`（快手极速版） |
| 关键权限 | 无障碍（BIND_ACCESSIBILITY_SERVICE）、SYSTEM_ALERT_WINDOW（悬浮日志窗）、FOREGROUND_SERVICE（mediaProjection 类型保活）、REQUEST_IGNORE_BATTERY_OPTIMIZATIONS、MANAGE_EXTERNAL_STORAGE、KILL_BACKGROUND_PROCESSES |
| 服务器 | `ask.xreader22.top:8443` / `update.xreader22.top`（卡密验证 + 互赞任务分发，自签 root.crt + RSA 加密参数） |
| 本地存储 | `files/redbag.xml`（全部福袋配置）、`files/fconfig.xml`（会员 uname/pass）、`files/parameter.xml`（设备指纹 devKey） |

**结论先行**：抢福袋逻辑**只对抖音实现**（`DyAct`，3357 行）；`KsAct`（快手）只实现刷视频/搜索/评论等"养号+任务"能力，未覆写 `tryGetRedBag()`。整套自动化是**轮询式**（线程循环抓 `rootInActiveWindow`），不是事件驱动——`onAccessibilityEvent()` 为空实现。

### 组件清单（AndroidManifest）

| 组件 | 作用 |
|---|---|
| `MainActivity`（LAUNCHER, singleTask） | 登录卡密、快捷模式按钮、权限引导、启动 ActionThread 与 CaptureService |
| `RedbagSetActivity` | 福袋设置页（`readRedbagConfig()` / `saveToFile()` 读写 redbag.xml） |
| `redbag.SetConfig` + 4 个 Fragment | 旧版设置页（基本/福袋/视频/直播 Tab），已废弃（方法体被 R8 清空） |
| `NoteActivity` / `UpdateActivity` | 说明与自更新（`http://<update_ip>:8000/app-release.apk`） |
| `CaptureService` | 前台 Service（通知 "祝您好运连绵不绝......"）+ MediaProjection 截屏能力 + 记录屏幕宽高 `mWindowWidth/mWindowHeight`（所有手势坐标的基准） |
| `util.TestAccessibilityService` | 无障碍服务本体（见 §6） |
| `FloatWindow` / `FloatImg` | 悬浮窗日志面板 |

---

## 2. 完整类清单（自有代码，109 个类；`*` = 核心自动化类）

### 2.1 act 包（自动化核心）

| 类 | 方法 | 说明 |
|---|---|---|
| `act.ActionThread`* | `run, doCommand, lookVideoByFree, askNewTask..., readHttps, initOkHttpsClient, checkInterruptedException` | **主循环线程**（§4.2） |
| `act.ActManager`* | `getRedbagStatus, tryGetRedBag, UpToAnotherVideo, adjustModel, keepInMainWnd, tryGetPlayerName, trySendUserInfo, returnToHot, slideUpOrDown, updateRunStateEx, doTask_Ks, jmpToPage, ...` | 平台选择 + 三段定时状态机 + 任务分发（§4.3） |
| `act.BaseAct`* | `findItem*, findItemAndclickBy*, Slide, clickFavorityForLiving, closeRedBagWhenIntoLiving, clearScreenForCommentInLiveRoom, doTask_jmp*, getWndState, isStrayInRightRoom, keepInMainWndInteval, lookAdVideo, returnToVideoByJmp(_quick), returnToVideoEx, shareVideo, shareVideoCopyUrl, collectVideo, commentVideo, findEditorAndSubmit, slideUpOrDown, tryGetRedBag, ...` | 平台无关基类：节点查找封装、滑动原语、深链回推荐页、点赞/评论/分享/收藏任务 |
| `act.DyAct`*（extends BaseAct） | `findRedBagNode, getRedbagNode, getRedBagType, readRedBagSecond(ByNode), clickRedBag, openRedBag, openRedBagNormal, openRedBagSupper, closeRegBagNote, getRedBagCondition, getSupperRedBagCondition, isConditionOk, tryGetRedBag, gotoLiveByLiveBtn, gotoLiveBySearch, gotoLiveSquare, gotoAttentionLive, gotoMyPage, returnToLiveWnd(NoRedBagException), clearLiveScreen, clearAlertWnfForLiveWnd, findCloseBtn, findCloseView, closeRedEnvelop, getWndState, isStrayInRightRoom, lookAdVideo, commentInStay, commentInVideo, commentVideo, favoriteIfMoreFavorites, findEditorAndSubmit, startLiveSpeek, attention, unAttention, validAttention, tryGetUserName, tryReadFavorityCount, tryReadShareCount, doShareTask, gotoAuthorPage(AndReadFansNum), isDiamondCanBuy, setBuyDiamondDelay, setSearchPageEx, updateRedbagParam, getNormalRegBagAttendCount/RewardCount, getSupperRegBagAttendCount/RewardCount, isDiamondRedbagComplete, isSupperRedbagComplete, getRedbagAttentionCount, testGuesture, ...` | **抖音抢福袋全部实现**（§4.5–4.10） |
| `act.KsAct` | `doTask, getWndState, slideUpOrDown, returnToVideo(Ex), closeRedBagWhenIntoLiving, clearScreen, commentInVideo, findEditorAndSubmit, findTargetInSearch, input_wordToSearch, setSearchPageEx, jmpToTaskPage, isStrayInRightRoom, closeRedEnvelop, tryGetUserName, ...` | 快手极速版：仅养号/任务，**无抢福袋** |
| `act.TaskAction`* | `askNewTaskAndDo, doTask, waitIfPause, setPause/Resume, tryCompleteTask, setAllActionAndTimeComplete, isLiveDoing/isLiveStaying/isVideoDoing/isRunning/isFree, getNextLiveTask, getPlayer/setPlayer, readUrls/writeUrls, ...` | 服务器任务（互赞互粉）执行状态 |
| `act.MyConfig`* | 全部 `s_*` 配置字段 + `setDefaultConfig*, setPlayConfig, adjustConfig, getAttendSecond, getLiveCommentForRedbag, getLiveFovoriteCountThisRoom, updateRedBagKeys, setRedbagKeyArrStr, setLiveCommentStr, isRedbagManual/isRedbagFix/isRedBagRewardLimitTitle` | 配置中心（§7） |
| `act.KaVerify` | `loginToServer, verifyKaAndGetEndTime, regClient, regNewLink, regAthor, askNewTask, askNewTaskByReadOnly, askNewLiveTask, askHasRequest, readUserInfoFromServer, getDyRealTargetUrl, getRealIp, decodeAskInfo(3DES-CBC), toMd5` | 卡密服务器通信（§9） |
| `act.GTaskItem` | `mTaskItemId/mActionType/mUrl/mComment/mCurCount/mRunningSecond...` 静态计数 `LookVideoCount, RedBagLookVideo, DoFavoriteCount, CompleteTaskId, TaskResultCount, AccountIsPunish, NeedFavoriteNormalVidue` | 服务器任务项 + 全局计数 |
| `act.TaskType / Taskstatus / BaseAct$MainWndState / BaseAct$ChangeListenType` | 枚举 | `MainWndState`: `NoInApp, Unkown, Video, Video_Search, Search, Live, PreLive, User, Total, Product, Menu*` |
| `act.ActionThread$1` / `DyAct$1` 等 | `$SwitchMap` 映射表 | — |

### 2.2 util 包（基础设施）

| 类 | 方法 | 说明 |
|---|---|---|
| `util.FindNode`* | `findRootNode, findDyRoot, findAllChildNodeLists(ByClass/ForTest), findNodeByText(List,*,idx), findNodeByContainText, findNodeByContainDescription, findNodeByViewId(AndRect/CanLook/Text), findNodeListByText(ByViewId/ByViewIdText), findNodeByClassName, findNodeByWidthAndHeight, findTextView, getNodeText/getNodeTxt/getNodeContentDescription, logAllNodes/logView/logTxt, setInterrupt, CheckInterrupt` | 无障碍节点查找库（§6.2） |
| `util.ActionNode`* | `performAutoClick, performAutoLongClick, performAutoDoubleClick, performAutoBack, goAutoHome, performAutoSlide, useGestureClickNode/Point, useGestureDoubleClickNode/Point, useGestureLongClickNode/Point, useGestureSlide, inputAutoText, isAccessibilityServiceOk` | 点击/滑动手势原语（§6.3） |
| `util.TestAccessibilityService`* | `onServiceConnected, onAccessibilityEvent(空), isDyActive, onInterrupt` | 无障碍入口（§6.1） |
| `util.GBase`* | `getSchemeUrl, getSecondFromString, jmpToPage, launchapp, killDouyinApp, isAppInstalled, moveToFront, randomInt, radomSleep, trySleep, tryConvertToInt/Double, tryGet*FromData, copyToClip, getClipContent, isSettingsWndAtMyFront, setLogToView/addLogToView/appendLogLine/getAllLog, addTxtToFile, base64_decrypt, getHtml, getIPAddressByHost, getPhoneBrand, getUrlFromRecommendString, setDyOriginal, ...` | 通用工具（`getSchemeUrl` 处理抖音普通版/极速版 id 前缀切换） |
| `util.GParameter` | `P_IN_REDBAG`（抢福袋中标志）、`s_devKey`（设备指纹，parameter.xml） | |
| `util.RedBagException / NoRewardException` | `m_type = 0/1/2` | 福袋循环内部流程控制"异常"（§4.10） |
| `util.ActionType / PlantType / PhoneType / ActModelType` | 枚举 | ActionType 29 个值（VideoLook...LiveSpeek）；PlantType {NOPLANT, KUAISHOU, DOUYIN} |
| `util.DeviceIdUtil / RomUtils / AESUtil / RsaUtil / UtilImage / FloatingView` | — | 设备指纹、加密、图片保存 |
| `util.GFClient / GFData / GUpLoad` | — | TCP socket 上报日志（可选 IP，主界面"服务器IP"输入框） |
| `image.ImageBase / ImageHelper` | — | 截屏图像辅助（配合 CaptureService，当前主流程未深度使用） |
| `ssl.*` | `HttpsUtils（3DES/RSA、信任 root.crt）、OkHttpSSLUtils、MyHttps、MyX509TrustManager...` | 自签 HTTPS |

### 2.3 UI/其它

| 类 | 说明 |
|---|---|
| `MainActivity` + 12 内部类 | 启动/停止、6 个快捷模式按钮、卡密登录 |
| `RedbagSetActivity` + 12 内部类 | 福袋设置页（`onStart` 绑定 UI ↔ MyConfig；`saveToFile`/`readRedbagConfig` ↔ redbag.xml；`saveItem`/`setSpinnerItemByValue`） |
| `redbag.SetConfig$CollectionPagerAdapter / LiveFragment / NormalFragment / RegbagFragment / VideoFragment / RegbagConfig` | 旧设置页残骸（空方法） |
| `FloatWindow / FloatImg / FloatingView` | 悬浮日志/图片窗 |
| `AutoUpdater` + 6 内部类 | 版本更新 |
| `databinding.* / BR / R*` | 生成代码 |

---

## 3. 线程与服务模型

```
MainActivity.startRunning()
  ├─ ActionThread.initOkHttpsClient()        // ask.xreader22.top:8443 + root.crt
  ├─ KaVerify.loginToServer("ttgf99","wfwfwf",15)   // 内置会员账号，返回 plant(1=抖音极速,2=快手极速)
  ├─ ActManager.setPlant(DOUYIN|KUAISHOU)
  ├─ startForegroundService(CaptureService)  // 保活 + 屏幕宽高记录
  ├─ FloatImg/FloatWindow 显示悬浮日志
  └─ new ActionThread().start()              // ★ 自动化主线程
```

- `TestAccessibilityService.onCreate/onServiceConnected` 只做一件事：`ActionNode.mAS = this`（静态引用），并补加 flag `FLAG_RETRIEVE_INTERACTIVE_WINDOWS(8)`。**主线程通过 `mAS.getRootInActiveWindow()` 主动轮询节点树**，`onAccessibilityEvent` 为空。
- 停止：`FindNode.setInterrupt()` 置中断标志，`findRootNode()`/手势原语在每次调用前 `CheckInterrupt()` 抛 `InterruptedException` 让主线程自然退出。

---

## 4. 核心自动化循环（精确伪代码）

### 4.1 总状态机

```
ActionThread.run():
  Looper.prepare(); copyToClip(" "); adjustModel(); reInit(); adjustConfig()
  while mContinue:
    # 0) 无障碍就绪检查（前 4 次循环内）
    if !ActionNode.isAccessibilityServiceOk():      # mAS!=null 且 getWindows().size()>0
        log("无障碍服务未加载成功,请重启手机后再试"); sleep(2000); continue
    if !TestAccessibilityService.isDyActive():      # findDyRoot()==null，抖音不在前台
        连续 6s：若设置页在前台 isSettingsWndAtMyFront → performAutoBack(1000)；sleep(2000)
        ActManager.keepInMainWnd(true)              # 强制回抖音推荐页
        sleep(3000)
    else:
        log("请不要操作,等待加载完成")
    TaskAction.waitIfPause()                        # 用户暂停/休息期挂起
    if isModelOk():                                  # mAct 已选平台
        keepInMainWnd(false)                         # 周期性纠偏（§4.11）
        tryGetPlayerName()                           # 我的页读抖音号（§4.13）
        trySendUserInfo()                            # KaVerify.regClient 上报
        TaskAction.tryCompleteTask()
    # 核心：最多连跑 10 次 doCommand
    repeat up to 10: if !doCommand(): break
    sleep(500)
```

```
ActionThread.doCommand():
  if 用户信息未初始化 → return lookVideoByFree()
  if 有服务器任务可领 askNewTaskAndDo() → return doTask()      # 互赞任务优先
  if g_readOnly: sleep(3000); return false
  status = ActManager.getRedbagStatus()                        # ★ 三段定时状态机
  switch status:
    case 0:  return false                                      # 次数达限/固定房已关 → 只做任务
    case 1:  # 刷视频期
             goAutoHome(5000)（仅 status 曾==1 特殊分支：goAutoHome+killDouyinApp+左右滑动防息屏）
             return lookVideoByFree() → UpToAnotherVideo()      # §4.4
    case 2:  ActManager.tryGetRedBag()                         # 抢福袋期 §4.5–4.10
             return false
```

### 4.2 三段定时状态机（ActManager.getRedbagStatus，静态 `redbag_status` + `redbag_nextResetTime`）

```
getRedbagStatus():
  if g_playOnly → return 0
  if (isRedbagManual() || isRedbagFix()) && x_redbagRoomIsClose → log("固定模式直播间已关闭"); return 0
  if isRedbagManual() → return 2                                 # 手动模式永远处于抢福袋期
  if (mode∈{0,1,2,5} 都允许) 且 isSupperRedbagComplete() 且 isDiamondRedbagComplete()
      → log("福袋参与次数超过限制,不再进直播间"); return 0
  if mode==1:  # 只抽抖币模式单独限额
      if attendCount ≥ s_iDiamondRedbagAttendLimit → log("抖币福袋参与次数超过限制"); return 0
      if rewardCount ≥ s_iDiamondRewardLimit      → log("抖币福袋获奖次数超过限制"); return 0
  if now ≥ redbag_nextResetTime:                                 # 定时翻转
      if status==1 且 s_iRedBagStatus_run_minute>0:
          status=2; nextReset=now+run_minute*60000; log("开始进行福袋作业"); return 2
      if status==3 且 s_iRedBagStatus_rest_minute>0:
          status=1; nextReset=now+rest_minute*60000; log("开始进行休息,N分钟后会自动运行程序"); return 1
      status=3; nextReset=now+playvideo_minute*60000
      log("为了更安全的抢福袋,现开始刷视频,持续时间N分钟")
      if run_minute>0: GTaskItem.LookVideoCount=85               # 刷视频期计数重置到阈值下方
  return status
```

周期（默认值）：**抢福袋 60min（run_minute）→ 刷视频 10min（playvideo_minute）→ [休息 rest_minute（默认 0 = 跳过）] → 抢福袋 …** 养号模式（mode=3）把 `run_minute` 置 0，状态机永远停留在刷视频。

### 4.3 逛推荐页（UpToAnotherVideo，抖音上下滑）

```
UpToAnotherVideo():
  if getWndState() != Video → keepInMainWnd(false) 纠偏后再取一次
  if state == Video:
      x = CaptureService.mWindowWidth/2  + randomInt(-40,40)
      y = CaptureService.mWindowHeight/2 + randomInt(-80,80)
      repeat ≤5:                                   # 一次 doCommand 最多滑 5 条
          waitIfPause()
          useGestureSlide((x, y+100) → (x, 50), duration=200ms)    # 上滑下一个视频
          sleep(5000)                                              # 每条视频固定看 5s
          if lookAdVideo() == 1: break                             # 遇广告则看广告(§4.14)
          radomSleep(0,10)                                          # 0~100ms 抖动
          GTaskItem.LookVideoCount += (run_minute<=0 ? 5 : 3)
```

- `lookAdVideo()`：若推荐页出现广告（`com.ss.android.ugc.aweme.lite:id/desc` 文本含 "... 广告"），停留 10s 并处理"点击重播"，50% 概率仅 `radomSleep(2,15)`，否则点作者头像进主页随机停留 15–30s 后返回（弹"直接退出"则点）。
- 判定"当前在推荐页"：`getWndState()==Video`，核心依据是存在 contentDescription 含 `点赞，喜欢` 的节点，或 `在线观众` 不存在（§5）。**不是**通过事件，而是每次全树扫描。

### 4.4 抢福袋总入口 ActManager.tryGetRedBag()

```
tryGetRedBag():
  GParameter.P_IN_REDBAG = true                       # 抢福袋中（评论输入框逻辑会分流）
  try:
      if !isRedbagManual(): mAct.tryGetRedBag()       # DyAct.tryGetRedBag §4.5
      else: while(true){ mAct.tryGetRedBag(); sleep(1000) }   # 手动模式死循环
  finally:
      P_IN_REDBAG = false
      mAct.returnToVideoByJmp_quick()                 # 深链回推荐页（§4.11）
      sleep(2000)
```

### 4.5 DyAct.tryGetRedBag —— 进房 + 房间内主循环

**进房（按优先级）：**

```
if mode==2（只抽关注）:
    gotoAttentionLive(): 我的→(下滑找)"关注"tab→点击→(下滑找)"直播中/直播"卡片→点击→sleep(7000)→进房
    失败 → log("进入直播间失败"); return
elif isRedbagManual():
    要求 getWndState()==Live（用户已手动进房），否则 return
elif isRedbagFix()  (mode==6):
    jmpToTaskPage(MyConfig.s_sFixLive)              # 直接深链进固定直播间（分享链接，剪贴板→getDyRealTargetUrl 解析）
else:
    A. gotoLiveByLiveBtn():                          # ① 推荐页底部"直播"tab
       returnToVideoByJmp_quick() → 找 contentDescription 以 "直播，" 开头的底部 tab
       找不到 → 在 [商城，/关注，/团购，/同城，/热点，/推荐，] 里取最靠左的 tab，
                 从其左侧 useGestureSlide((tab.left,cy)→(W*0.8,cy),500ms) 把 tab 栏左滑露出"直播"，重试 2 次
       点击"直播"tab → sleep(5000) → 等待文本"点击进入直播间"（直播广场卡片，最多 2×4s）→ 点击第一张卡片 → 进房
       失败置 g_bNoLiveBtn=1
    B. 若 A 失败/skip：gotoLiveBySearch(key)：         # ② 搜索关键词进房
       key = (mode==1) ? "钻石福袋直播间" : (s_sSearchKey 非空 ? s_sSearchKey : "带货直播间")
       ActManager.jmpToPage("search") → 深链 snssdk2329://search
       输入框 com.ss.android.ugc.aweme.lite:id/fl_intput_hint_container → ACTION_SET_TEXT(key)
       点"搜索" → 结果页找 "反馈入口, 按钮"，遍历其父的 FrameLayout 子项点击（第一个直播卡片）→ sleep(8000)
    C. 若 B 失败：performAutoBack(2000) + returnToVideoEx() + gotoLiveSquare():  # ③ 直播广场
       点 contentDesc "侧边栏"；找不到则点 (55, 顶部分类tab.centerY())；
       找文本 "直播广场" → 点击；若当前页是侧栏（"我的钱包/观看历史/小程序"）
       → useGestureSlide((W/3, H/2+100)→(W/3,50),600ms) 上滑侧栏找"直播广场"；
       sleep(8000) → 要求 getWndState()==Live
    A/B/C 全失败 → return（本轮放弃，主循环继续刷视频）
```

**房间内主循环（while isSuitForRedBag()，即 status==2）：**

```
sleep(3000)
v15 = 60            # 本次会话最多"换房"60 次
v13_1 = 0; v12 = ""; v16_1 = 0; v17 = 0; v8_0 = 0; v7 = 0
while ActManager.isSuitForRedBag():
    if isDiamondRedbagComplete() && isSupperRedbagComplete():
        log("福袋任务已经完成"); break
    updateRedbagParam()                        # 跨天重置计数器
    TaskAction.waitIfPause()

    node = findRedBagNode(12)                  # ★ 轮询 12s 找福袋图标（§4.6）
    if node == null 且 isRedbagFix():
        if now > v13_1(=发现福袋后25s): log("25秒未发现福袋,重进"); throw RedBagException(2)
    if mode != 2:
        if v15 <= 0: log("重新进一次"); g_bReInRoom=0; performAutoBack(2000); break
    else:
        # 关注模式：若主头部出现"关注"入口 → 列表已滚动到底
        if 找到 user_name 节点附近"关注"按钮: log("重新浏览一遍关注列表"); throw RedBagException(2)

    if g_bSetLiveQuality:                      # 首次进房降清晰度省流量
        点 contentDesc "更多面板 按钮" → 点"清晰度" → 点"标清" → returnToLiveWnd()

    if !manual && !fix:                        # 卡死检测
        name = com.ss.android.ugc.aweme.lite:id/name_layout 的 child(0).text   # 主播昵称
        if name 与上次相同: v16_1++ ; if v16_1 >= 4:
            log("无法上下移动,卡住了,先退出"); performAutoBack(1000); break
        else: 记住 name, v16_1=0

    if node != null:                           # —— 房间里有福袋 ——
        # ① 在线人数过滤
        desc = contentDescription 含 "在线观众" 的节点
        count = 解析 desc（支持"N万"→*10000）
        if count>0 且 count < s_iPersonCountMin: log("非手机平板,放弃"); skip=1
        if count ≥ s_iPersonCountMax: log("人数超过N,放弃"); skip=1
        # ② 类型识别与限额
        seconds = readRedBagSecond(node.contentDescription)      # §4.6
        if desc 含 "超级福袋":
            if mode != 1:
                if seconds > s_iRedbagSupperLimitTime*60: log("超级福袋时间太长,不参与")
                elif supper_attendCount ≥ s_iSupperRedbag_AttendLimitCount: log("超级福袋超过次数限制"); skip=1
                else: log("扫超级福袋"); v8_0=1; goto OPEN
            else: log("设置不参与超级福袋,放弃")
        elif desc 含 "生活":
            log("生活福袋")                       # 团购福袋（type=3），继续走 OPEN
        else:                                     # 普通抖币/钻石福袋
            if mode == 0: log("非超级福袋,放弃")   # 超级福袋模式不抢普通福袋
            elif attend/reward 超限: log(...)
            elif seconds > s_iRedbagDiamondLimitTime*60: log("福袋时间太长,不参与")
            else: log("检测到钻石福袋"); v8_0=0; goto OPEN
        OPEN:
            if skip==0 且 v17==1（刚上滑换的房）: log("开福袋前等待"); sleep(randomInt(3,10)*1000); v17=0
            if skip==0: openRedBag()              # §4.7
    else:                                      # —— 房间里没有福袋 ——
        if 存在 "m.l.live.plugin:id/ttlive_dialog_guide_float_window_action_cancel":
            log("关闭悬浮窗"); 点击之; sleep(2000)
        else:
            if clearLiveScreen(nodes): continue   # 关"抢幸运数字/限时任务/开宝箱/立即打开"弹窗（§4.8）
            if live_play_container 不存在 且 getWndState()∈{Video,Menu,Search}:
                log("直播间意外退出了"); break
            closeRegBagNote(nodes, v8_0)          # 开奖结果处理（§4.9）
            if !inLive: returnToLiveWnd(); if !inLive: log("直播间意外退出了2"); break
catch RedBagException e:
    if e.m_type == 1:  if !returnToLiveWndNoRedBagException(): break; skip=1; continue
    if e.m_type == 2:  break                          # 退出循环 → 回推荐页
    # m_type == 0（换房指令）:
    if !manual && !fix && skip!=0:
        v15--
        useGestureSlide((W/2±40, H/2±80+100) → (W/2±40, 50), 300ms)   # ★ 上滑切下一个直播间
        sleep(s_iWaitForNextRedbag * 1000 + 100)                      # ★ 换房间等待（默认 5s）
        v17 = 1
    continue
end:
if !isRedbagManual(): returnToVideoByJmp(false)       # 深链 snssdk2329://feed/ 回推荐页
```

> **"从推荐页自动发现福袋直播间"的精确机制**：它**不识别推荐页卡片上的福袋标记**。它通过（①底部"直播"tab → 直播广场点第一张卡片 / ②搜索关键词"带货直播间/钻石福袋直播间/自定义"点结果卡片 / ③侧边栏→直播广场）进入直播间后，在**左上角区域（left<600 且 top<550 px）**扫描 contentDescription 为 `超级福袋 X分X秒` / `福袋，X分X秒` 的图标节点；没有福袋就 `RedBagException(0)` 触发 300ms 上滑切下一个直播间，等待 `s_iWaitForNextRedbag`（默认 5s）后继续，60 次换房后强制退出重进（回推荐页再走 ①→②→③）。另外它通过 `link_seat_anim_recyclerview`（连麦位）与 `user_avatar`（已不在直播间）判断福袋不可得并立即换房。

### 4.6 福袋识别与分类（节点匹配规则）

**findRedBagNode(seconds)**：每 1s 轮询 `getRedbagNode()`，最多 seconds 秒；期间若出现 `m.l.live.plugin:id/live_end_count_down`（直播已结束倒计时）→ 返回 null。

**getRedbagNode()**：
1. 若存在 `m.l.live.plugin:id/link_seat_anim_recyclerview`（连麦布局）→ `throw RedBagException(1)`（此房无福袋，退回直播间清屏）。
2. `findAllChildNodeLists(root, false)`（全树、仅 isVisibleToUser）后：
   - `findNodeByContainDescription(list, "超级福袋 ")`（尾随空格）→ 命中即候选；
   - 否则 `findNodeByContainDescription(list, "福袋，")`（中文逗号）→ 候选；
   - 候选**位置过滤**：`getBoundsInScreen().left < 600 && top < 550`（屏幕左上角福袋挂件区）；
   - 若 `s_bTeamBuy`：再找 contentDescription `生活服务-直播-福袋`（团购福袋入口）。
3. 若存在 `com.ss.android.ugc.aweme.lite:id/user_avatar`（说明已退出直播间，位于普通视频页）：
   - 非固定模式 → `throw RedBagException(1)`；
   - 固定模式且当前不在直播页 → 置 `x_redbagRoomIsClose=true` 并 `throw RedBagException(2)`（固定房已关）。

**getRedBagType(node)**（按 contentDescription）：
| contentDescription 包含 | type | 含义 |
|---|---|---|
| `超级福袋` | 2 | 超级福袋（观看任务型，带"参考价值"） |
| `生活` | 3 | 团购/生活服务福袋 |
| 其它（`福袋，X分X秒`） | 1 | 普通抖币/钻石福袋 |

**readRedBagSecond(desc)**：倒计时解析（contentDescription 即倒计时，抖音会自动刷新）：
- `超级福袋 3分20秒` → `getSecondFromString(去前缀)`；
- `福袋，2分15秒` → 同上；含 `生活` → 固定 100；
- `getSecondFromString`: 找 `分` 前的数字 = 分钟，`分` 到 `秒` 之间的数字 = 秒，`min*60+sec`；解析失败返回 0（超级福袋 0 → 直接放弃本轮）。

### 4.7 openRedBag()（分发 + 复试）

```
openRedBag():
  first = true
  repeat ≤5:
      if manual 且 !inLive: return
      t = clickRedBag(null, 3)                 # 点福袋图标，最多 3 次
      if t == -1: log("福袋时间过长,放弃"); return            # 超时类型
      if t == 0:  # 点不开：可能有"关闭福袋"确认浮层
          if 找到文本"关闭福袋" → 点击; sleep(1000); continue else break
      # t==1 普通福袋 / t==2 超级福袋 / t==3 生活福袋
      if t==1:
          if diamond_attendCount ≥ s_iDiamondRedbagAttendLimit: log("钻石福袋限制参与N次"); return
          if first: log("打开钻石福袋看看")
          if !openRedBagNormal(): break        # §4.7.1
      if t==2:
          if supper_attendCount ≥ s_iSupperRedbag_AttendLimitCount:
              log("识别到超级福袋,当前参与次数超过限制,放弃"); return
          openRedBagSupper()                   # §4.7.2
          if manual 且 !inLive: return
      if t==3: openRedBagSupper()              # 团购福袋走超级福袋面板逻辑
      clearLiveScreen(allNodes)                # 清任务弹窗
  returnToLiveWnd()
```

**clickRedBag(node, times)**：循环 times 次（node 为空则 `findRedBagNode(12)`）；type==2 时先解析 contentDescription 倒计时：`seconds > s_iRedbagSupperLimitTime*60` → 返回 -1；`seconds==0` → 返回 0；否则 `useGestureClickNode(node)` + sleep(2000)，成功（type>0）即退出。

#### 4.7.1 openRedBagNormal（普通抖币/钻石福袋，精确算法）

```
deadline = now + 600000            # 整个面板最多盯 10 分钟
firstLog = false
while now < deadline:
    nodes = allNodes
    cd = retry5(300ms): findNodeByText(nodes,"倒计时")       # 面板上的"倒计时"字样
    if cd == null:
        if 找到"已参与": 刷新节点; sleep(3000); continue      # 已参与，等开奖
        if !closeRegBagNote(nodes, supper=false): return 1   # 出了中奖/未中奖弹窗并已处理
        node = findRedBagNode(8)                              # 弹窗关了但福袋没了
        if node==null 或 node.text 含 "超级福袋": return 0     # 只处理普通福袋
        useGestureClickNode(node); sleep(2000); continue
    else:
        if 存在"粉丝团点亮且达到": log("钻石福袋难度太大,放弃"); return
        parent = cd.getParent()
        idx = 在 parent 子节点中找到文本=="倒计时" 的下标 i
        minutes = int(parent.child(i-1).text[0:2])            # "05" 分
        seconds = int(parent.child(i+2).text)                  # "33" 秒
        total = minutes*60 + seconds
        cond = getRedBagCondition(nodes)                       # §4.7.3
        if cond < 0: log("钻石福袋难度太大,放弃"); return
        joined = findNodeByContainText(nodes,"人已参加")
        joined_n = int(joined.text 截到 "人" 前)
        if total > s_iRedbagDiamondLimitTime*60: log("钻石福袋时间太长,放弃"); return
        if joined_n < 1: log("非钻石福袋,放弃"); return        # 没人参加的不是钻石福袋
        # ★ 参与概率启发式（人数比阈值）
        if total < 60:  P = (270 - total) / 600.0
        else:           P = (360 - total * 0.75) / 900.0
        if cond==1（需发评论）: P += 0.4
        elif cond==2（需加粉丝团）且 mode!=1: P += (redbag_attentionCount<=30 ? 0.2 : 0.1)
        if joined_n / joined_count ≤ P:                        # 人数少=中奖概率高 → 参与
            attendSec = MyConfig.getAttendSecond()             # §7 参与时机
            首次 log("准备参与福袋,等待时间到%d内再参与")
            if total < attendSec+1:                            # 到点了 → 真正参与
                if 找到"去发表评论":
                    diamond_attendCount++
                    点击"去发表评论"; sleep(3000); 点"发送"; sleep(3000)
                    clickRedBag(null, 3)
                else:
                    btn = findNodeByContainText(nodes,"粉丝团（1钻石）")
                    if btn==null 且 cond==2:
                        if 全树无"收益可抵扣钻石": setBuyDiamondDelay(1200); log("无钻石,无法开福袋"); return
                        btn = cd.parent.parent 的最后一个 child
                    if btn != null 且 redbag_attentionCount < s_iAttentionLimit:
                        redbag_attentionCount++; 点击 btn; setBuyDiamondDelay(180); sleep(2500)
                        if 出现"确认并不再提醒" → 点击; sleep(3000)     # 花 1 钻石确认框
                        clickRedBag(null, 3)
            else:
                sleep(total <= attendSec+5 ? 100 : 3000)       # 还没到点，密歇
        else:
            log("获奖概率太低,换房间"); return 0
```

#### 4.7.2 openRedBagSupper（超级福袋，精确算法）

```
likeN   = MyConfig.getLiveFovoriteCountThisRoom()   # 本房点赞次数(0=本次不点)
cmtWord = MyConfig.getLiveCommentForRedbag()        # 本房评论(概率抽中)
attendSec = MyConfig.getAttendSecond()
deadline = now + 900000                              # 最多盯 15 分钟
priceLogged = 0; joinedOnce = 0
while now < deadline:
    nodes = allNodes
    cd = retry5(300ms): findNodeByContainText(nodes, " 后开奖")     # "X 后开奖"行
    if cd == null:
        n = findRedBagNode(1); if n: 点击(n); sleep(2000)             # 面板被关了 → 重开
        if closeRegBagNote(nodes, supper=true):
            n2 = findRedBagNode(12)
            if n2==null: return 0
            if getRedBagType(n2)==2: 点击(n2); sleep(2000)            # 回到超级福袋面板
            else: return 0
        else: return 1
    else:
        if 存在"粉丝团点亮且达到" 或 "活动已经结束": log("超级福袋任务太难,放弃"); return
        parent = cd.getParent()
        i = 找到 text==cd.contentDescription 的 child 下标（从 5 扫到 20）
        # 参考价值：节点 "¥0参考价值: ¥XX"（前缀 "¥0参考价值: ¥"）
        priceNode = findNodeByContainText(nodes, "¥0参考价值: ¥")
        price = priceNode ? double(priceNode.text.replace("¥0参考价值: ¥","")) : 0
        if priceLogged==0: log("福袋参考价:"+price); priceLogged=1
        if s_bTeamBuy: 分钟:秒 形式 child(i-3).text.split(":") → total
        else:
            minutes = int(parent.child(i-3).text); secNode = parent.child(i+3)
            if secNode 含 "后开奖": secNode = parent.child(i+2)
            total = minutes*60 + int(secNode.text)
        cond = getSupperRedBagCondition(nodes)                     # §4.7.3
        if cond < 0: log("超级福袋任务无法完成,放弃!"); return
        if findNodeByContainText(nodes,"观看"): attendSec = 1000000  # 有"观看"任务 = 挂机即可
        # —— 金额过滤（价值数据来源 = 面板"参考价值"文本解析）——
        if cond > 1 且 diamondConstCount < s_iDiamondSpendLimit:
            if price ≥ s_iAddFansTeamIfMoneyIsMore 且 s_bAddFansTeam:
                if priceLogged==1: log("价格贵重,所以冒险一次加入粉丝团"); priceLogged=2
            else: log("金额未达到加粉丝团条件,放弃!"); return
        if total==0: log("抽奖结束"); closeRegBagNote(nodes,true); returnToLiveWnd(); throw RedBagException(0)
        if 找到"参与成功 等待开奖"或"活动已经结束": return 2
        task = 找到"开始观看直播任务"（优先点击开启观看任务）
        btn = "一键发表评论" → 否则 "参与抽奖" → 否则 "发送评论"
        if btn 含 "转发直播间"：按 s_bTeamBuy 处理"转发直播间"→"复制链接"
        fanBtn = s_bTeamBuy ? "加入粉丝团（1抖币）" : "加入粉丝团"
        if fanBtn 存在且其文本含 "1钻石"或"1抖币":
            if diamondConstCount ≥ s_iDiamondSpendLimit: log("钻石花费超过限制,放弃"); return
            点击 fanBtn; setBuyDiamondDelay(300); sleep(3000)
            处理"确认并不再提醒"/"取消确认并不再提醒"（后者点其右侧 -150px 处，即"确认"）
            clearAlertWnfForLiveWnd(); …
        elif btn==null: sleep(3000); continue
        else:
            if total > 15: log("参与前随机等候"); sleep(randomInt(3,8)*1000)
            supper_attendCount++
            点击 btn; sleep(3000)
            if 出现"发送" → 点击（发送面板要求的评论）; sleep(3000)
            clearAlertWnfForLiveWnd(); returnToLiveWnd()
            # ★★ 挂机到开奖 + 中途点赞/评论
            endT = now + total*1000 + 1000
            while now < endT:
                n = getRedbagNode(allNodes)
                if n:
                    s = readRedBagSecondByNode(n)
                    if s <= 0: break
                    log(s+"秒后开奖"); endT = min(now+s*1000+1000, endT)
                    if s > 30:
                        if likeN > 0: log("给主播点赞"); clickFavorityForLiving(likeN); likeN=0
                        elif cmtWord 非空: log("给主播评论"); startLiveSpeek(cmtWord); returnToLiveWnd(); cmtWord=""
                sleep(300)
            closeRegBagNote(allNodes, true)
            throw RedBagException(0)
```

#### 4.7.3 参与条件检查

`getRedBagCondition(nodes)`（普通福袋面板）——出现下列文本即 `return -1`（放弃）：`粉丝团点亮且达到`、`转发`、`分享直播间`、`仅会员可参与`、`不满足参与条件`；含 `加入粉丝团`/`点亮粉丝团` 且下一格文本含 `未达成`（isConditionOk 找同级下一 child）→ cond=2；含 `发送评论：` 且未达成 → cond=1；cond=2 且不能买钻石（`isDiamondCanBuy`：now > sNextBuyDiamondTime）→ -1。

`getSupperRedBagCondition(nodes)`（超级福袋面板）——额外检测 `即将开奖 无法参与`、`会员未达成`、`加入购物粉丝团未达成`(cond=2)、`加入直播粉丝团未达成`(cond=3)；cond∈{2,3} 时若 `redbag_attentionCount ≥ s_iAttentionLimit` → log("此任务需要关注,关注数量限制,放弃") 返回 -1；cond=3 且不能买钻石 → -1。

### 4.8 clearLiveScreen / clearAlertWnfForLiveWnd（弹窗清理）

- `clearLiveScreen(nodes)`：文本 `抢幸运数字` → back(2000)；`限时任务` → back(3000)（再检查一次"抢幸运数字"再 back）；`开宝箱`/`立即打开` → 点"立即打开"右侧兄弟（关闭按钮 `parent.child(1)`）或 back(3000)。返回 true 表示清了东西。
- `clearAlertWnfForLiveWnd()`：最多 3 轮。已回直播页 → 返回 1；处于 Video/搜索/用户页 → `throw RedBagException(2)`；否则找关闭按钮 `findCloseView`（contentDescription==`关闭`/`退出` 且宽>600 的全屏浮层）：
  - 有 `findCloseBtn`：优先找类名 `com.lynx.tasm.ui.image.FlattenUIImage` / `com.bytedance.android.live.lynx.ui.CustomUiImage` 且 75×75–90×90 px 的关闭图标，否则文本 `关闭福袋`；可点击则点击，不可点击则（若同屏有"抢"）点"抢"按钮的最后一个兄弟，然后 back(3000)。
  - 没有关闭按钮 → back(3000) 兜底。

### 4.9 开奖结果处理 closeRegBagNote(nodes, isSupper)

```
if 找到 contentDesc 含 "重新加载" → 点击; sleep(2000); return true
win = findNodeByText("我知道了") ?? findNodeByText("知道了")
if win:                                    # —— 未中奖 ——
    s_iSameRoomLose++; log("遗憾未中奖")
    if isRedbagFix(): returnToLiveWnd(); throw RedBagException(1)
    if s_iSameRoomLose ≥ s_iToNextRoomAfterLoseNum:      # 连续 N 次不中奖强制换房（默认 999=关闭）
        returnToLiveWnd(); s_iSameRoomLose=0
        throw RedBagException(mode==4 ? 0 : 1)
    点击 win; sleep(500); returnToLiveWnd()
    sleep(s_iWaitForNextRedbag*1000 + 100)               # 未中奖后等下一个福袋
    return 0
# —— 中奖/获奖面板 ——
winTxt = "领取奖品" ??"恭喜你！" ??"赠送主播礼物表示心意"          # 普通福袋中奖
teamWin = "恭喜抽中福袋"                                            # 团购福袋中奖
if 都没找到: return returnToLiveWnd()
if !isSupper: diamond_rewardCount++
else:          supper_rewardCount++
if !isSupper 且 界面含 "钻石":
    log("中奖了~~~~!!!!!,脚本已暂停,一分钟后继续运行"); sleep(60000)
elif isSupper:
    if !teamWin:
        if !s_bdoAfterReward: log("中奖了~~~~!!!!!,脚本已暂停"); sleep(1000000000)  # 无限期挂起！
        else: log("中奖了~~~~!!!!!,一分钟后继续"); sleep(60000)
    else: log("已中团购福袋,一分钟后继续运行"); sleep(60000)
performAutoBack(1500)
return 0
```

### 4.10 RedBagException 语义（流程控制专用异常）

| m_type | 抛出场景 | catch 行为 |
|---|---|---|
| 0 | 超级福袋开奖结束；固定连续未中奖(mode4)；点"重新加载"外的流程复位 | 非手动/非固定且 skip 标志已置位时：**v15--，上滑 300ms 切下一个直播间，sleep(s_iWaitForNextRedbag) ，标记 v17=1（下轮先随机等 3–10s 再开福袋）** |
| 1 | 普通福袋连败达到阈值；连麦位布局出现；退出直播间后又在房间 | `returnToLiveWnd()` 清理回直播页后继续在本房间轮询 |
| 2 | 直播已结束/意外退出主界面；固定房关闭；25s 未发现福袋（固定模式）；v15 用尽 | `break` → `returnToVideoByJmp(false)` 深链回推荐页 |

### 4.11 回到推荐页（退出直播间的方式）

**不是靠连按返回**，而是优先深链直达：

```
returnToVideoByJmp(quick=false):
  url = DOUYIN ? "snssdk2329://feed/" : KUAISHOU ? "ksnebula://home/hot/" : ""
  jmpToPage(url)                        # view.post { startActivity(Intent(ACTION_VIEW, Uri.parse(url))) } + sleep(5000)
  if wantWait:
      if random(1,2)==1: Slide(1)       # 随机先上滑一下
      等 ≤4s 直到 getWndState()==Video
  否则:
      if random(1,3)==1: clickAllBtns() # 兜底：点 50–135px 的可点节点关闭残留弹窗
returnToVideoByJmp_quick(): 同上但 sleep(1000)（抢完福袋后的快速返回）
returnToVideoEx():                     # 逐状态纠偏循环（≤2 轮）:
  state = getWndState(); if Video → true
  returnToVideo(state): 按 state 分支处理:
    Live:      非直播任务时点 com.ss.android.ugc.aweme.lite:id/root → Slide(4)(右滑最小化)
    Video:     直接成功
    Menu:      back(1000)
    Search/Video_Search: 点 com.ss.android.ugc.aweme.search_lite_plugin:id/back_btn_left；
               否则找 id/ox2 中文本=="推荐" 的 tab（父节点 contentDescription 不含"已选中"则点），
               再点 id/pmu
    User:      点 contentDesc "首页，按钮"
    PreLive:   点 id/back_btn
    NoInApp:   returnToVideoByJmp(false)
    Unkown:    ★ 兜底大杂烩（见 §8）: winStateErr++ >6 → 双 back；
               点权限弹窗 packageinstaller/permissioncontroller 的 deny/allow、抖音 close/clh/clg/cb6、
               "没有响应"→确定、"无响应"→关闭应用、"累了吧，休息一下"→取消、
               ttlive 引导浮窗取消、aim/ail/ai1 时点 <80×80 可点节点等
```

### 4.12 直播间点赞与评论

- **点赞** `clickFavorityForLiving(n)`：循环 n 次 `useGestureDoubleClickPoint((W/2±80, H/3±40))`（双击屏幕中上部 1/3 处），间隔 100–300ms，每次之间调 `closeRedBagWhenIntoLiving()` 防误触。触发概率与次数：`getLiveFovoriteCountThisRoom()` = `randomInt(0,100) ≤ s_iLiveFavoriteRate`（默认 30%）时返回 `randomInt(s_iLiveFavoriteMin, s_iLiveFavoriteMax)`（默认 5–50），否则 0。仅超级福袋等待开奖且剩余 >30s 时执行一次。
- **评论** `startLiveSpeek(text)`：找 `m.l.live.plugin:id/edit_btn_audience` 或文本 `说点什么...` → 点击 → `findEditorAndSubmit`（直播路径）：找 `m.l.live.plugin:id/edit_text_container` → `child(0)` → `inputAutoText`（`ACTION_SET_TEXT` 直接写入，非键盘）→ sleep(5000) → 点 `m.l.live.plugin:id/tv_send_portrait` 发送；备用路径：文本 `说点什么...` → `parent.child(0).child(0)` → 点文本 `发送`。评论内容概率：`getLiveCommentForRedbag()` = `randomInt(0,100) ≤ s_iLiveCommentRate`（默认 0 = 关闭）时从 `s_arr_liveCommentWords`（默认 `主播太帅了/真好/太完美了/优秀/Perfect!`）随机一条。
- 视频页评论（任务）：点 `comment_container` → 编辑框（`善语结善缘`/`有爱评论` 占位或"插入图片"的兄弟）→ setText → 点 `id/bij` 或文本 `发送` → back。

### 4.13 每日上限、定时与养号

- **每日计数器**（DyAct 静态字段，`updateRedbagParam()` 日期变更时清零）：`redbag_diamond_attendCount / redbag_diamond_rewardCount / redbag_supper_attendCount / redbag_supper_rewardCount / redbag_attentionCount(加粉丝团/关注次数) / redbag_diamondConstCount(花钻石次数)`。
- **限额判定**：`isDiamondRedbagComplete()` = attend≥`s_iDiamondRedbagAttendLimit`(50) 或 reward≥`s_iDiamondRewardLimit`(5)；`isSupperRedbagComplete()` = attend≥`s_iSupperRedbag_AttendLimitCount`(100)。
- **定时养号**：§4.2 的三段状态机 + 养号模式 mode=3（只刷视频）；`updateRunStateEx()` 处理运行/暂停：resume 时 `g_nextRestTime = now + s_iRunTimeMinute*60000`；暂停时 kill 抖音 + goHome。
- `redbag_firstTenMiniteEnd = now + 3000000`（50 分钟）初始；手动/关注/固定模式置 500000000（≈永不到期）。
- 视频计数 `LookVideoCount`（GTaskItem 静态，初始 90）：向服务器请求真实任务前需 ≥100（否则以"仅播放"身份请求）；抢福袋轮转时被赋 85，点赞/评论/关注后赋 70，刷视频每条 +3/+5。

### 4.14 主播昵称/在线人数读取

- 主播名：`com.ss.android.ugc.aweme.lite:id/name_layout` 的 `child(0).text`（房间内卡死检测）。
- 在线观众：contentDescription 含 `在线观众` 的节点（`在线观众1234` / `在线观众1.2万`）。
- 抖音号：我的页文本含 `抖音号：` 节点 → `parent.parent.parent.parent.child(i).child(0).text`；读不到两次记 `noreader1`，登录异常提示"当前账号未登录"。

---

## 5. getWndState()：页面判定（DyAct 版）

优先级从上到下（每次全树扫描）：

| 判据 | 结论 |
|---|---|
| findDyRoot()==null | `NoInApp` |
| `com.ss.android.ugc.aweme.lite:id/title` 存在且 text==`正在直播` | `Unkown`（载入中） |
| title 存在但非"正在直播"：找"我的钱包"，left>0 → `Menu`；contentDesc 含 `在线观众` → `Live`，否则 `Video` |
| `com.ss.android.ugc.aweme.lite:id/ohe` 存在（无 title） | 沿用上面的 Menu/Video 分支 |
| `m.l.live.plugin:id/live_play_container` 存在 | `Live` |
| `com.ss.android.ugc.aweme.lite:id/user_name` 存在 | `Live` |
| `id/scroll_layout` 存在 | `User` |
| 文本 `本场点赞` | `Live` |
| 文本 `我的钱包` / `常用小程序` / `常用功能` | `Menu` |
| 文本 `点击进入直播间` / `免费下载` / `提交,按钮` / `点击重播` / contentDesc `点赞，喜欢` | `Video` |
| contentDesc `人看过` | `Live` |
| contentDesc `旗舰店` 且 top<200 | `Live` |
| 文本 `搜索` 且 contentDescription==`搜索` | `Search` |
| 其它 | `Unkown` |

---

## 6. 无障碍服务实现

### 6.1 服务配置（res/TH.xml → @7F140000）

```xml
<accessibility-service
    android:accessibilityEventTypes="0xFFFFFFFF"   <!-- 监听全部事件（实际不用） -->
    android:accessibilityFeedbackType="0xFFFFFFFF"
    android:notificationTimeout="100"
    android:accessibilityFlags="0x53"              <!-- DEFAULT | FLAG_INCLUDE_NOT_IMPORTANT_VIEWS |
                                                        FLAG_REPORT_VIEW_IDS | FLAG_REQUEST_FILTER_KEY_EVENTS -->
    android:canRetrieveWindowContent="true"
    android:canRequestFilterKeyEvents="true"
    android:canPerformGestures="true"/>            <!-- dispatchGesture 手势注入 -->
```
未配置 `android:packageNames` → 接收所有包（代码里用 `findDyRoot()` 按 `com.ss.android.ugc.aweme` 包名过滤窗口）。`onServiceConnected` 时追加 `FLAG_RETRIEVE_INTERACTIVE_WINDOWS(0x8)` 以启用 `getWindows()`。

### 6.2 节点查找（FindNode）

- `findRootNode()` = `mAS.getRootInActiveWindow()`，为空则 `findDyRoot()`（遍历 `mAS.getWindows()` 找包名含 `com.ss.android.ugc.aweme` 的窗口根）。
- `findAllChildNodeLists(root, log)`：DFS 收集**所有可见**（`isVisibleToUser()`）节点为扁平 List —— 之后所有查找都在这个 List 上线性 `equals/contains`：
  - `findNodeByText(list, txt, idx)`：`text.trim().equals(txt)`（精确，第 idx 个）；
  - `findNodeByContainText(list, s)`：`text.contains(s)`（模糊）；
  - `findNodeByContainDescription(list, s)`：`contentDescription.contains(s)`；
  - `findNodeByViewId(root, id, idx)`：`root.findAccessibilityNodeInfosByViewId(id)`（viewId 查找用系统 API，全限定 id 如 `com.ss.android.ugc.aweme.lite:id/xxx`；极速版/普通版差异由 `GBase.getSchemeUrl()` 统一处理——`m_bDyOriginal` 时把 `.lite` 去掉、`snssdk2329`→`snssdk1128`）；
  - 几何辅助：`findNodeByViewIdCanLook`（有宽高才算）、`findNodeByViewIdAndRect`、`findNodeByWidthAndHeight(w,h,clickable)`。
- 关键抖音/直播 viewId（常量）：
  - `m.l.live.plugin:id/live_play_container`（直播间容器）
  - `m.l.live.plugin:id/short_term_icon_layout`（**左上角福袋挂件容器 DY_LIVE_REDBAG_FRAM**）
  - `m.l.live.plugin:id/live_end_count_down`（直播结束倒计时）
  - `m.l.live.plugin:id/anchor_info_container`、`m.l.live.plugin:id/link_seat_anim_recyclerview`（连麦位=无福袋）
  - `m.l.live.plugin:id/edit_text_container` / `edit_btn_audience` / `tv_send_portrait`（直播间评论）
  - `m.l.live.plugin:id/ttlive_dialog_guide_float_window_action_cancel`（直播引导浮窗取消）
  - `com.ss.android.ugc.aweme.lite:id/*`：user_name、user_avatar、name_layout、title、scroll_layout、desc、viewpager、comment_container、bij、back_btn、root、close、ohe、pmu、ox2、no6、et9、aim/ail/ai1、clh/clg/cb6、fl_intput_hint_container…
  - `com.ss.android.ugc.aweme.search_lite_plugin:id/back_btn_left`；`com.android.packageinstaller:id/permission_deny_button`；`com.android.permissioncontroller:id/permission_allow_foreground_only_button` / `permission_deny_button`

### 6.3 手势/动作原语（ActionNode，全部经 mAS）

| 原语 | 实现 |
|---|---|
| `performAutoClick(node)` | node.isClickable → `performAction(ACTION_CLICK)` + `performAction(ACTION_LONG_CLICK)`；否则降级 `useGestureClickNode` |
| `useGestureClickNode(node)` | 取 `getBoundsInScreen` 中心点 → `useGestureClickPoint` |
| `useGestureClickPoint(p)` | `dispatchGesture(GestureDescription{Path.moveTo(x,y), StrokeDescription(path,0,50ms)})` —— **50ms 单点手势** |
| 双击 | 两次单击 + `sleep(100)` |
| 长按 | `StrokeDescription(path,0,duration)`（默认 2000ms） |
| `useGestureSlide(from,to,ms)` | `Path.moveTo→lineTo` + `StrokeDescription(path, 0, ms)`，一次直线滑动（无中间点） |
| `performAutoBack(ms)` | `performGlobalAction(GLOBAL_ACTION_BACK)` + sleep |
| `goAutoHome(ms)` | `performGlobalAction(GLOBAL_ACTION_HOME)` + sleep |
| `inputAutoText(node,txt)` | `performAction(ACTION_SET_TEXT, {ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE: txt})`（免键盘输入） |
| `performAutoSlide(node,forward)` | 可滚动节点 `ACTION_SCROLL_FORWARD/BACKWARD` |

坐标基准全部来自 `CaptureService.mWindowWidth/mWindowHeight`（MainActivity onCreate 时记录）。

---

## 7. 配置项对照表

### 7.1 真实配置存储：`files/redbag.xml`（标签名 = MyConfig 字段名）

`RedbagSetActivity.readRedbagConfig()`（每次点"开始执行"前读取）↔ `saveToFile()`（设置页"保存设置"= `updateRedbagConfigToParam` 写入）：

| XML 标签 | MyConfig 字段 | 语义 | 默认值（setDefaultConfig） | UI 控件（设置页文案） |
|---|---|---|---|---|
| s_iRedBagStatus_run_minute | s_iRedBagStatus_run_minute | 每轮抢福袋持续分钟（sp_runRedbagMinute） | 60 | "1 先刷 [N] 分钟福袋(这个数值不要设置成0)" spinner[0,30,60,90,120] |
| s_iRedBagStatus_playvideo_minute | 同名 | 两轮抢福袋之间刷视频分钟（sp_playAfterRedbag） | 10 | "2 再刷 [N] 分钟视频,提升账号活跃,提高命中率" spinner[5,10,20,30,40,50,60,90,120] |
| s_iRedBagStatus_rest_minute | 同名 | 休息分钟（sp_restAfterRedbag） | 0 | "3 最后休息 [N] 分钟,然后重新跳回第一步刷福袋" spinner[0,10,20,40,60,90,120,180,240] |
| s_iNomalRedbagAttendLimit | s_iDiamondRedbagAttendLimit | 抖币福袋每日最多参与次数 | 50 | "抖币福袋每日最多参与 [N] 次" |
| s_iDiamondRewardLimit | 同名 | 抖币中奖超过 N 次后不再参与 | 5 | "抖币中奖超过 [N] 次后不再参与" |
| s_iRedbagDiamondLimitTime | 同名 | 抖币福袋领取倒计时超过 N 分钟放弃 | 4 | "抖币福袋领取时间超过 [N] 分钟放弃" |
| s_iSupperRedbag_LimitCount | s_iSupperRedbag_AttendLimitCount | 超级福袋每日最多参与次数 | 100 | "超级福袋每日最多参与 [N] 次" |
| s_iAttentionLimit | 同名 | 每日最多关注/加团主播数（到达后不再加团、条件任务放弃） | 15 | "每日最多关注 [N] 个主播" |
| s_iRedbagSupperLimitTime | 同名 | 超级福袋开奖倒计时超过 N 分钟放弃 | 15 | "超级福袋领取时间超过 [N] 分钟放弃" |
| s_iPersonCountLimit | s_iPersonCountMax | 直播间人数超过 N 放弃 | 200000 | "超级福袋直播间人数超过 [N] 人放弃" |
| s_iToNextRoomAfterLoseNum | 同名 | 同一房间连续 N 次不中奖强制换房 | 999（≈关闭） | "同一个房间几次不中奖强制换房间:" |
| s_bdoAfterReward | 同名(bool) | 超级福袋中奖后是否继续抽奖 | false | CheckBox "超级福袋中奖后是否继续抽奖(要小心不要漏领奖品)" |
| s_bTeamBuy | 同名(bool) | 抽团购福袋 | false | CheckBox "抽团购福袋(需要将想要的团购直播间加入关注并选择抽关注模式)" |
| s_iSupperRedbag_noAttendMoney | 同名 | 只参与参考价格 ≥ N 元的超级福袋 | 50 | "只选择参考价格 [N] ~ [M] 元之间的超级福袋"（下限） |
| s_iSupperRedbag_noAttendMaxMoney | 同名 | 参考价格 > M 元放弃 | 99999 | 同上（上限） |
| s_bAddFansTeam | 同名(bool) | 是否加粉丝团（花 1 钻石/抖币） | true | CheckBox "是否加粉丝团" |
| s_iAddFansTeamIfMoneyIsMore | 同名 | 加团条件：参考价值需达到 N 元 | 2000 | "加团条件:参考价值需达到 [N]" |
| s_iAttendTimeSel | 同名 | 参与时机（sp_attendtime） | 6（立马开启） | "设置什么时间段开始参与福袋" spinner：0完全随机(45–900s) 1一分钟以内(45–60s) 2两分钟以内(45–120s) 3 0-5分钟(45–300s) 4 5-10分钟(300–600s) 5 5-15分钟(600–900s) 6立马开启(100000=即抢) 7精确指定(分+秒) |
| s_iAttendMinute / s_iAttendSecond | 同名 | 精确指定的 剩余分/秒（<3s 自动抬到 3s） | 0/0 | "精确指定剩余多久参与福袋(不小于3秒): [分][秒]" |
| s_iWaitForNextRedbag | 同名 | 换房间等待秒数（sp_waitForNextRedbag） | 5 | "换房间等待 [N] 秒再开始操作" spinner[0,5,10,15,20,30,60] |
| s_iDoRedBagReward | 同名 | 只抽指定奖品（sp_onlyDo） | 0 | "只抽指定奖品的超级福袋" spinner：0自动判断(抽所有) 1只手机 2只平板 3只苹果 4只华为 5只手机平板 6自定义关键词 |
| s_arr_redbag_keys | s_arr_redbag_keys | 自定义关键词（空格/逗号分隔） | 空 | "自定义福袋关键词设置__关键词之间用空格分开 如:手机 平板 华为 苹果" |
| s_iRedbag_Mode | 同名 | 执行模式（sp_regbagMode） | 0 | "选择执行模式" spinner：0超级福袋 1只抽抖币 2只抽关注 3养号模式 4手动进直播间 5钻石和超级福袋（6=固定直播间，仅由"固定直播间"快捷按钮设置） |
| s_iDyVersion | 同名 | 抖音版本（sp_dyVersion） | 0 | "选择抖音版本" spinner：0自动判断 1抖音 2抖音极速版（→ GBase.setDyOriginal 切换 id 前缀） |
| s_iLiveFavoriteRate / Min / Max | 同名 | 直播间点赞触发概率% / 次数范围 | 30 / 5 / 50 | CheckBox "直播间点赞触发概率 [N]% 次数 [A]~[B]" |
| s_iLiveCommentRate | 同名 | 直播间评论触发概率% | 0 | CheckBox "直播间评论触发概率 [N]%" |
| s_arr_liveCommentWords / s_cmtwords | 同名 | 评论内容（/ 分隔，去空项） | 主播太帅了/真好/太完美了/优秀/Perfect! | "评论内容(每句以/隔开)" |
| s_sSearchKey / s_sFixLive | 同名 | 搜索关键词 / 固定直播间深链 | "" / "" | 仅由快捷按钮设置（渔具/酒水预设、固定直播间=剪贴板分享链接） |

> **注意**：字符串池里的 `sp_attendtime/sp_dyVersion/sp_onlyDo/sp_playAfterRedbag/sp_regbagMode/sp_restAfterRedbag/sp_runRedbagMinute/sp_waitForNextRedbag` 是设置页随 `updateRedbagConfigToParam/onStart/updateToCtrl` 写入的 **SharedPreferences（default 共享首选项）镜像键**，但 `MainActivity.onCreate` 每次启动都会 `getDefaultSharedPreferences(this).edit().clear()` 把它们清掉 —— 实际持久化与生效路径是 **redbag.xml → MyConfig 静态字段**。做 iOS 复刻时以 MyConfig 字段语义为准即可。

### 7.2 快捷模式预设（MainActivity 按钮）

| 按钮 | 预设 |
|---|---|
| 手机模式（btn_quickstart_mobile） | setDefaultConfigForMobile：PersonCountMin=2000、DoRedBagReward=5(只手机平板)、AddFansTeamIfMoneyIsMore=1500，其余默认 |
| 关注模式（btn_quickstart_attention） | setDefaultConfigForAttention：mode=2、noAttendMoney=1、DiamondLimitTime=8 |
| 钻石福袋（btn_quickstart_diamond） | mode=1、AttentionLimit=10 |
| 普通模式（btn_quickstart_normal） | setDefaultNormal：mode=5 |
| 养号模式（btn_quickstart_play） | setPlayConfig：mode=3（run_minute=0 → 状态机永远刷视频） |
| 渔具直播间（btn_quickstart_fish） | mode=5 + onlyDo=6 + 关键词"渔/竿/虫/蚯蚓/鱼/饲料/线/箱/米/卷/漂/钓/饵/轮" + SearchKey"渔具直播间" + AttentionLimit=5 + AddFansTeamIfMoneyIsMore=50 + noAttendMoney=1 |
| 酒水直播间（btn_quickstart_wine） | mode=5 + onlyDo=6 + 关键词"酒/洋河/茅台/糊涂仙/古井/浓香/酱香/度/五粮液" + SearchKey"酒水直播间" + AttentionLimit=5 + AddFansTeamIfMoneyIsMore=100 + noAttendMoney=10 |
| 固定直播间（btn_quickstart_fix） | 剪贴板分享链接 → KaVerify.getDyRealTargetUrl 解析出 live 深链 → s_sFixLive，mode=6，PersonCountMax=10000000 |

### 7.3 非配置类运行时状态

| 字段 | 语义 |
|---|---|
| ActManager.redbag_status / redbag_nextResetTime | 三段定时状态机当前态/翻转时刻（初始 1 / 0） |
| ActManager.g_sShouldSetRunState | 1=resume（g_nextRestTime=now+RunTimeMinute）、-1=暂停（杀抖音+HOME）、-2=暂停+10min 后可再跑 |
| MyConfig.g_nextRestTime | 暂停/恢复用的下一次检查时刻 |
| DyAct.sNextBuyDiamondTime | "买钻石冷却"——isDiamondCanBuy 的依据（参与需钻任务后 setBuyDiamondDelay(180/300/1200s)） |
| DyAct.x_redbagRoomIsClose | 固定模式直播间已关闭标志 |
| GTaskItem.LookVideoCount / RedBagLookVideo(=1000) | 刷视频计数（>=100 才领真任务） |
| GParameter.P_IN_REDBAG | 抢福袋中（评论输入逻辑分流用） |
| FindNode.m_findNOde_interrupt | 停止标志（CheckInterrupt 抛 InterruptedException） |

---

## 8. 状态容错与兜底

1. **重试无处不在**：`findItemThreeTimes(id, n)`（间隔 1.5s）、`findRedBagNode(12)` 12s 轮询、面板内找"倒计时"5×300ms、`gotoLiveBySearch` 10×1s 等。
2. **卡死检测**：房内主播名连续 4 轮不变 → back 退出；`getWndState()==Unkown` 连续计数 `winStateErr`>3 → back，>6 → 双 back；`setCheckWndStateTime(5/30)` 控制 keepInMainWnd 纠偏周期。
3. **弹窗兜底**（returnToVideo 的 Unkown 分支）：系统权限弹窗（packageinstaller/permissioncontroller）、抖音隐私弹窗（close/clh/clg/cb6）、登录验证窗（"验证并登录"+playOnly 时 back）、ANR（"没有响应"→确定 / "无响应"→关闭应用）、青少年/休息提醒（"累了吧，休息一下"→取消）、直播引导浮窗（ttlive cancel）、装机推荐小弹窗（aim/ail/ai1 时点 <80×80 可点节点）、"立即打开/开宝箱/限时任务/抢幸运数字/签到提醒"。
4. **三层返回策略**：优先深链（`snssdk2329://feed/`）→ 次选按状态点对应返回控件 → 最后 performAutoBack；`returnToLiveWnd` 失败 3 次抛 type2 整体退出重进。
5. **全局兜底**：`closeRegBagNote` 未识别的面板一律 `returnToLiveWnd()`；`openRedBag` 循环 5 次后强制 `returnToLiveWnd`；doCommand 最多连跑 10 次后 sleep(500) 重置；换房计数 v15=60 防死循环；`InterruptedException`（停止按钮）直达线程退出。

---

## 9. 服务器交互（KaVerify，可忽略/伪造）

- 主机：DNS `ask.xreader22.top`（getRealIp(2)）→ `HttpsUtils.mHostName = "<ip>:8443"`；更新 `update.xreader22.top`；证书 assets/root.crt 固定信任。
- 接口（均 `https://<host>/ask.aspx?action=...`，返回 `OK_<3DES+Base64>` 或 `ERROR<code>`；请求参数 RSA(public.pem) 加密）：
  - `verify`（卡密验证）、`login`（内置账号 ttgf99/wfwfwf）、`regcc`（设备注册，devKey=DeviceIdUtil.getDeviceId 的 MD5）、`read`（读用户信息/积分）
  - `newtask`（领互赞任务：`code=RSA(rand+plant+clientID)`，返回 `id_type_runsecond_url_comment`）、`live`（直播任务：上灯牌/点赞/评论）、`gr`（只读模式任务）、`reguu`、`athor`
- 3DES 解密：key=Base64("YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4")（"abcdefghijklmnopqrstuvw"），IV=固定 8 字节 {32,12,55,8,96,38,17,58}，CBC。
- 对 iOS 复刻的意义：本地抢福袋循环完全不依赖服务器；服务器只提供（a）启动校验/统计（b）互赞互粉任务。复刻时可以整段去掉或替换为自己的统计。

---

## 10. iOS 越狱插件复刻要点（映射建议）

| 安卓机制 | iOS 对应 |
|---|---|
| AccessibilityService + getRootInActiveWindow | 越狱后私有框架：`UIAccessibilityPerformEscape` 不可用，需自建 AX 运行时（`AXUIElement`/`UIAccessibility` 后门）或用 `_AXSAccessibilityController`；节点树可参照 SpringBoard 辅助 API / `XBAX` 思路 |
| dispatchGesture（50ms 点击/直线滑动/双击/长按） | `IOHIDEventSystemClient` 注入触摸（或 `SBStashGesture`/`libhookject`），保持 50ms 时长与随机 ±40/±80 抖动 |
| performGlobalAction(BACK/HOME) | `SBUIController`/`FBSDashboard` 私有调用或 `activator` send event |
| ACTION_SET_TEXT 输入 | 直接对 UITextField `setText:`（hook 级别比无障碍更稳） |
| 深链 `snssdk2329://feed/`、`snssdk2329://search`、`ksnebula://home/hot/` | `openURL:`（相同 scheme 可用） |
| 节点文本匹配（福袋/超级福袋/倒计时/我知道了…） | 全部匹配串与流程逻辑（§4.5–4.9）可原样移植，只需替换取节点树与取 text/contentDescription 的底层 |
| redbag.xml 配置 | 保留字段语义（§7.1 表）做 tweak 的 NSDictionary 设置 |
| 三段定时状态机/概率公式/金额过滤 | 纯逻辑，照抄：`P = (270-t)/600 (t<60)；(360-0.75t)/900 (t≥60)；评论+0.4；加团+0.2/0.1` |

**复刻时的关键差异点提醒**：
1. 抖音 viewId（`com.ss.android.ugc.aweme.lite:id/xxx`、`m.l.live.plugin:id/xxx`）随抖音版本变化，iOS 端建议以文本/contentDescription/几何区域匹配为主，viewId 仅作辅助。
2. 福袋挂件位置过滤 `left<600 && top<550` 是像素值（分析机型相关），iOS 端应按屏幕比例（约左上角 1/3 宽 × 1/4 高）实现。
3. `sleep(1000000000)`（超级福袋中奖且未开"中奖后继续"）在 iOS 端应实现为可取消的暂停态。
4. 本 APK 的快手侧没有抢福袋实现；iOS 复刻如果只做抖音，工作量集中在 DyAct 一条链路。
