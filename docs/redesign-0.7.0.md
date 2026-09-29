# 0.7.0 全自动引擎重做设计（基于两份深度逆向）

来源：`docs/android-fudai-analysis.md`（安卓福袋助手 1.700 精确伪代码）+ `docs/sjj-2852-analysis.md`（抖音优化 28.52 完整 hook 链路）。

## 核心修正（相对 0.6.x 的错误方向）

| 0.6.x 的错误做法 | 真实机制 |
|---|---|
| 扫描推荐页卡片上的"福袋"文字进房 | 安卓：**不识别推荐页卡片**。进房走①feed 底部"直播"tab→直播广场点卡 ②搜索关键词 ③侧边栏直播广场 |
| 全屏找"福袋"文字 | 进房后只在**左上角区域**（约屏宽 1/3 × 屏高 1/4）找福袋挂件：`超级福袋 X分X秒` / `福袋，X分X秒` |
| 没袋就退房回推荐页再进 | 没袋 → **直播间内上滑换下一个房间**（300ms 手势 + 等 5s），最多换 60 个房间才深链回推荐页重进 |
| 调 scrollToNextVideo 切视频 | iOS 正解（siwenjiajia 实测）：**5 个门卫 hook 强制抖音原生自动连播接管**；scrollToNextVideo 仅在广告跳过时用 |
| 无时长/概率判断 | 普通福袋按概率公式过滤，超级福袋按面板"参考价值"金额过滤，倒计时超限放弃 |

## 刷视频期（Browse）实现 = siwenjiajia 门卫 hook（照抄最小清单）

**5 个强制 hook**（method_setImplementation 替换，orig 保存用于关闭时透传；类不存在逐空跳过）：
- `AWEAwemeDetailTableViewController - hasIphoneAutoPlaySwitch` → YES
- `AWEAwemeDetailContainerPlayControlConfig - enableUserProfilePostAutoPlay` → YES
- `AWEFeedIPhoneAutoPlayManager - isAutoPlayOpen` → YES
- `AWEFeedIPhoneAutoPlayManager - getFeedIphoneAutoPlayState` → 1
- `AWEFeedModuleService - getFeedIphoneAutoPlayState` → 1

**两级开关**：总开关 `sjj_auto_play_feature_enabled_v1` + 运行开关 `sjj_auto_play_active_v1`（+DYYY 兼容键），全局字节缓存；生效=总开&&运行开。hook 体：开关双开才返回 YES，否则透传 orig。
无需定时器/滚动/播放进度——推进由抖音原生自动连播引擎完成。

可选增强：`AWEFeedTableViewController - playVideo:` hook（广告→`onAwemeDeleted:isDislike:NO silentlyDelete:YES` + `scrollToNextVideo`，配 5s dispatch_after 重试）。

## 抢福袋期（Grab）实现 = 安卓 DyAct 链路照抄

三段状态机：Grab(60min,可配)→Browse(10min,可配)→Rest(0min 默认跳过)→Grab…；养号=Grab 时长 0。

### 进房（按优先级降级）
a. feed 底部"直播"tab（a11y 以 `直播，` 开头；找不到则对 tab 栏做左滑手势）→ 直播广场（等 `点击进入直播间`）→ 点第一张卡 → sleep 5s
b. 深链 `snssdk1128://search`（标准版抖音 search 路由）→ 输入关键词（"带货直播间"/"钻石福袋直播间"/自定义）→ 点结果第一张直播卡
c. 侧边栏 → 直播广场
全失败 → 本轮放弃，深链回 feed。

### 房内主循环（换房上限 60）
1. 扫左上角（x<40% 屏宽, y<30% 屏高）找 `福袋`+`X分X秒` 节点 → 解析类型与剩余秒
2. 没福袋 → 上滑换房：找**直播间容器**（Live 页 VC 子树的竖向分页 UIScrollView，安卓的 300ms 上滑等价）→ 调其翻页方法/scrollToItem+补发 `scrollViewDidEndDecelerating:` → 等 `waitNextRoom`(5s)
3. 有福袋 → 人数过滤（`在线观众N`，N万→*10000，超 `maxRoomSize` 换房）→ 类型限额（普通参与/中奖、超级参与各自上限）→ 时长过滤（普通>4min、超级>15min 换房）→ 点福袋挂件 → 面板流程（§下）
4. 卡死检测：主播昵称（a11y）4 轮不变 → back 换房；直播结束倒计时 → 换房；Unknown 连续>3 → back，>6 → 深链回 feed
5. 每次循环若处于手动模式则无限循环（安卓 manual 死循环）

### 普通福袋面板（openRedBagNormal 照抄）
- 找面板"倒计时"行 → 读 分/秒 + `N人已参加`
- 概率公式：`P=(270-t)/600 (t<60)；(360-0.75t)/900 (t≥60)`；需评论 +0.4；需加团 +0.2(关注≤30)/0.1
- `joined_n/总人数 ≤ P` 才参与；到参与时机（attendMode：0随机45-900s 1≤1分 2≤2分 3≤5分 4 5-10分 5 5-15分 6立马(默认) 7精确分秒）→ 点"去发表评论"→填模板→"发送"；或"粉丝团（1钻石）"（受每日加团/钻石限额）
- 条件过滤：`粉丝团点亮且达到`/`转发`/`仅会员可参与`/`不满足参与条件` → 放弃

### 超级福袋面板（openRedBagSupper 照抄）
- 找 `X 后开奖` 行 + `¥0参考价值: ¥XX` 解析金额 → 金额 < 50 或 > 99999 放弃；加团条件（参考价值≥2000 且开关开）
- 任务按钮：`开始观看直播任务` / `一键发表评论` / `参与抽奖` / `发送评论`；加团按钮（1抖币/1钻石，受钻石花费上限）
- 参与 → **挂机到开奖**：剩余 >30s 时点赞（30% 概率 5~50 次）/评论（概率，模板），倒计时结束处理开奖结果

### 开奖结果
- `我知道了`/`知道了` → 点击（未中奖，计数+1，连续 N 次不中强制换房，默认 999=关）
- `领取奖品`/`恭喜你！` → 中奖计数+1 → 暂停 60s（可配）→ 继续

### 容错
`重新加载`→点击；`抢幸运数字`/`限时任务`/`开宝箱`/`立即打开` 弹窗清理；`直播已结束`→换房；换房计数 v15=60 防死循环。

## 页面判定（getWndState 的 iOS 版，a11y 文本判据）

一次 pass 顺带收集：`在线观众`/`本场点赞`→Live；`点赞，喜欢`→Video(feed)；`点击进入直播间`→LivePlaza；`我的钱包`→Menu；`抖音号：`→User；`搜索`+`搜索`→Search；判据全缺→Unknown。

## iOS 手势替代（无 dispatchGesture）

- 点击：UIControl sendActions / 手势 target 调用 / accessibilityActivate（现有 FDTap）
- 滑动换房/切视频：内部方法（门卫 hook 原生连播 / 直播间容器翻页方法）+ scrollToItem + 补发 `scrollViewDidEndDecelerating:`
- 输入：UITextField/UITextView setText（等价 ACTION_SET_TEXT）
- back：navigationController pop / 深链 `snssdk1128://feed/`

## 配置面板（对齐安卓设置项，默认值照抄 §7.1 表）

新增：抢福袋时长(分)=60 / 刷视频时长(分)=10 / 休息时长(分)=0；抖币参与上限=50 / 中奖上限=5 / 领取超时(分)=4；超级参与上限=100 / 开奖超时(分)=15 / 参考价下限=50 / 上限=99999；只抢X人以内=200000；换房等待(秒)=5 / 换房上限=60；直播点赞概率=30% / 次数5~50 / 评论概率=0% / 模板；参与时机=6(立马)；加粉丝团开关 / 加团条件=2000 / 每日关注上限=15；搜索关键词；模式 0超级 1抖币 2关注 3养号 4手动 5钻石+超级(默认5)。

暂不做：互赞任务（服务器）、团购福袋、固定直播间深链、快手。

## 实施顺序

1. 门卫 hook（Browse 自动连播）+ 两级开关 + 面板
2. 页面判定 + 三段状态机 + 配置持久化
3. 直播链路：进房 → 左上角福袋扫描 → 直播间内上滑换房
4. 普通/超级福袋面板算法 + 开奖处理 + 容错
5. 实测调参
