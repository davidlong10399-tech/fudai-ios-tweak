# 福袋助手 iOS（抖音适配）

这是对 `福袋助手.apk` 的 iOS 越狱重写版，不是 APK/DEX 转换。第一版将 Android 的无障碍节点查找、定时器和状态机映射到抖音 iOS 进程内的 Objective-C/ UIKit hook。

## 目标

- 仅注入 `com.ss.iphone.ugc.Aweme`。
- 监听已有的抖音福袋/红包类和 selector。
- 发现候选入口后按延迟、冷却和每日上限推进状态。
- 提供可拖动的悬浮按钮，用于显示状态和启停。

## 构建

需要 macOS、Theos、iOS SDK 和 arm64/arm64e toolchain：

```sh
export THEOS=/opt/theos
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

产物在 `.theos/obj`/packages 目录。当前开发环境为 Windows，未检测到 Theos、Apple SDK 或 `xcrun`，因此这里提供完整源码和包元数据，但无法在本机产出可安装 deb。

## 安装

将生成的 deb 传到越狱设备后执行：

```sh
dpkg -i com.fudai.ios_0.1.0_iphoneos-arm.deb
killall -9 Aweme
```

## 配置

使用 `NSUserDefaults` 键：

- `fudai.enabled`：总开关，默认开启
- `fudai.delayMinutes`：发现后延迟触发分钟数，默认 0
- `fudai.cooldownSeconds`：触发冷却秒数，默认 20
- `fudai.dailyLimit`：每日次数上限，默认 30，0 表示不限
- `fudai.debug`：是否写入 `[FuDai]` 日志

## 兼容性与诊断

目标类/selector 均通过 Logos 运行时查找；目标版本缺少某个方法时由 Logos 跳过该 hook，不应因此阻止进程启动。启用 `fudai.debug` 后用系统日志查看 `[FuDai]` 记录。

首版依赖已有抖音 Objective-C 类线索，未实现快手 iOS bundle 适配，也没有直接复刻 Android `AccessibilityService` 或 `CaptureService`。如果抖音版本改名了类/selector，需要重新从运行时类列表确认后更新 hook 表。
