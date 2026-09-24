# Android → iOS 迁移报告

## 输入样本

- APK：`D:\Liu\新建文件夹\福袋助手.apk`
- 包名：`com.android.greaderex`
- 入口：`com.android.greaderex.MainActivity`
- 关键组件：`RedbagSetActivity`、`redbag.SetConfig`、`CaptureService`、`util.TestAccessibilityService`
- 目标 Android 包：抖音/抖音极速版、快手极速版

## 已确认的 Android 行为

1. 通过 `AccessibilityService` 查找直播/视频中的红包或福袋节点。
2. 使用 `findRedBagNode`、`tryGetRedBag`、`clickRedBag` 等流程进行识别和点击。
3. 使用 `openRedBagNormal`/`openRedBagSupper` 等模式，以及 `sp_runAfterRedbagMinute`、`sp_restAfterRedbag`、`sp_waitForNextRedbag` 等时间配置。
4. 用前台服务、屏幕捕获和状态机维持后台运行。

## iOS 映射

| Android | iOS 第一版 |
|---|---|
| AccessibilityService / AccessibilityNodeInfo | 抖音目标类、视图生命周期和 selector hook |
| `findRedBagNode` / `tryGetRedBag` | `AWEIMDouyinRedPacketComponent`、`AWEIMDouyinRedPacketDataManager`、`AWELuckyCatBannerView` 事件观察 |
| `clickRedBag` | 目标 App 自身 Objective-C 事件链；不直接改业务数据 |
| SharedPreferences | `NSUserDefaults` |
| Foreground Service / Handler | GCD timer + 主线程生命周期管理 |
| Android overlay | 独立 UIKit `UIWindow` 浮动按钮 |
| CaptureService | 首版不迁移，优先使用目标 App 内部 UI 事件 |

## 已采用的 iOS 证据

已有抖音插件二进制出现以下类/selector 线索：

- `AWEIMDouyinRedPacketComponent`
- `AWEIMDouyinRedPacketDataManager`
- `AWEIMDouyinRedPacketTransferManager`
- `AWELuckyCatBannerView`
- `openRedPacketWithOrderId:completion:`
- `openRedPacketWithOrderId:extParams:completion:`
- `fetchRedPacketInfoWithOrderId:completion:`
- `fetchRedPacketInfoWithOrderId:params:completion:`
- `redPacketDidTapped`

## 未覆盖项

- 快手 iOS bundle 和对应类/selector 尚未采集。
- Android 屏幕捕获、无障碍节点层级和跨 App 权限模型没有直接等价物，当前使用目标进程内部事件替代。
- iOS 目标版本升级可能改变 Swift/Objective-C 类名和 selector；缺失 hook 会被跳过，但功能需要重新验证。
- 本机 Windows 环境没有 Theos、Apple SDK、`xcrun`，未生成最终 deb。

## 验收重点

- plist 只过滤抖音 bundle。
- 所有触发器受总开关、冷却时间和每日上限约束。
- 目标页面/进程退出时不依赖后台悬挂 Android 服务。
