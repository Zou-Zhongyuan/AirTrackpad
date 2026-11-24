# 从 Unified Remote 到自研 AirTrackpad：用 Swift 6 与 Safari PWA 复刻 Mac 原生触控板手感

> 开源仓库：[https://github.com/Zou-Zhongyuan/AirTrackpad](https://github.com/Zou-Zhongyuan/AirTrackpad)  
> 在线作品展示页：[https://zou-zhongyuan.github.io/AirTrackpad/](https://zou-zhongyuan.github.io/AirTrackpad/)  
> macOS 安装包下载（v1.0.0）：[https://github.com/Zou-Zhongyuan/AirTrackpad/releases/latest](https://github.com/Zou-Zhongyuan/AirTrackpad/releases/latest)

平时在 Mac 上使用触控板时，我几乎不会把它「用力按下去」——所有交互都靠轻点左键、双指右键与惯性滚动、双指捏合缩放、三指拖动、三指轻点查词，以及四指切桌面、调度中心、App Exposé、显示桌面与启动台完成。

之前我用 Unified Remote 在 iPhone 上临时充当触控板，虽然基本移动和点击很可靠，但它的交互逻辑更接近传统的「鼠标垫 + 快捷按钮」，和 macOS 原生触控板的肌肉记忆差距不小：缺少三指拖动抬指接力、四指空间切换和双指惯性手感都不够自然。于是我干脆自己从零写了一套轻量专属方案 **AirTrackpad**，并把它完整开源出来分享给大家。

---

## 一、架构取舍：为什么选择「原生菜单栏 App + iPhone Safari PWA」？

决定自己写之后，第一个关键决策是 iPhone 端形态：

- 如果写原生 iOS App，固然可以使用硬件级 `UITouch` 采样与 Taptic 触感反馈，但个人免费开发者账号编译安装到真机每 **7 天就要过期重签**，分享给别人用门槛也太高。
- 改用 **iPhone Safari 全屏 PWA（添加到主屏幕）**，零安装、零证书过期烦恼、扫一次二维码添加到主屏幕就能长期全屏秒开；而把所有复杂的惯性插值、亚像素累加、核心权限和系统事件合成都放在 **Mac 原生 Swift 6 菜单栏 App** 里，兼顾了极致轻量和接近原生的手感。

最终落地的系统采用**零第三方依赖**设计：
- **Mac 端**：Swift 6 编写的 `LSUIElement` 纯菜单栏常驻应用（仅依赖 `AppKit`、`SwiftUI`、`Network`、`CryptoKit`、`CoreImage`、`ServiceManagement`、`CoreGraphics`、`SystemConfiguration` 等系统框架），无需完整 Xcode，仅凭 macOS Command Line Tools 就能直接编译打包。
- **iPhone 端**：原生 HTML/CSS + 纯 ES Module（`gesture-engine.js`），无需任何 npm 构建步骤，99% 面积为省电纯黑 OLED 触控区。

---

## 二、让手机真正「像触控板」的几个核心细节

### 1. 错峰落指升级与 230ms 防微抖动轻点

人手把三指或四指放到手机屏幕时，并不可能在同一毫秒触屏，通常会横跨 40~80ms。因此手势引擎内部设计了阶梯式宽限窗口：

`IDLE → MAYBE_ONE → MAYBE_TWO → MAYBE_THREE → MAYBE_FOUR`

只要在宽限窗口内新增手指，状态机就会直接平滑晋升到对应手势，绝不会在四指扫屏前先误吐出光标移动或 `dragStart`。

另外还解决了一个在真实触屏上非常致命的细节：**人类单指轻点通常持续 60~150ms，而指腹压扁接触电容屏时几乎必然产生 1~3px 的 `touchmove` 抖动**。如果仅因停留超过 45ms 就切入移动状态，大量正常轻点会被直接吞掉。将轻点时间晋升窗口对齐 `230ms`（而位移阈值仍保持敏感的 `5px`），既实现了移动零迟滞，又让单/双/三击轻点稳定触发。

### 2. 复刻三指拖动「0.4 秒短暂抬指接力」

手机屏幕不如 Mac 触控板宽大，拖一个窗口跨屏或者拉选一段很长的代码时，手指经常划到边缘。AirTrackpad 完整复刻了 macOS 原生三指拖动最精华的**抬指接力**体验：

- 三指划动进入 `THREE_DRAG` 时，客户端发送 `dragStart`；Mac 端合成 `.leftMouseDown` 时**显式指定 `kCGMouseEventClickState = 1`**，避免刚轻点完立刻三指拖动时被系统误认成双击拖选。
- 当三指全部抬起时，客户端不急着发送 `dragEnd`，而是开启一个默认 `400ms` 的接力计时器（可在手机设置 `0ms–800ms` 任意调整或关闭）：
  - `400ms` 内三指重新落回屏幕：立刻取消计时器无缝继续拖拽；
  - `400ms` 内单指轻点一下：立刻冲刷 `dragEnd` 并吞掉这次轻点，适合确认放下文件后马上停手；
  - 若期间断网或超过 `5s` 心跳超时，Mac 端也会按 `clientID` 精确释放左键，彻底杜绝左键卡死。

### 3. 相对软件方向锁定：告别横屏二次旋转 Bug

横放 iPhone 可以大幅增加三指与四指的横向操作空间，但很多人平时会在 iPhone 控制中心锁住「竖屏方向锁定」。AirTrackpad 提供了独立的「锁定横屏（Home 条在右/左）」选项，并且依据当前视口宽高与 `screen.orientation.angle` 计算**相对旋转角**：

- 手机开启了系统竖屏锁（视口仍为竖屏 `0°`）且设置锁定横屏 `90°` 时，引擎对位移矢量施加 `270°` 旋转补偿；
- 如果你关闭了系统竖屏锁且 iOS 自己已经把网页旋转到横屏 `90°`，相对旋转角会自动算出 `0°`，**绝不会发生双倍旋转 90° 的错乱**。

### 4. 亚像素累加 + 120Hz 惯性滚动 + macOS 26 Tahoe 系统避坑

- **滚动与惯性**：`CGEvent(scrollWheelEvent2Source:units:.pixel)` 接收整数像素，慢速双指滚动若直接取整会丢帧卡顿。我们在 Mac 端维护了浮点余数累加器 `ScrollAccumulator`，配合 120Hz `DispatchSourceTimer` 指数衰减惯性输出，并动态写入 `field 137`（自然滚动标志位）。
- **四指全手势与 Tahoe Apps**：实测验证 macOS 26 Tahoe 的 `Apps.app` 依然通过 `CoreDockSendNotification("com.apple.launchpad.toggle")` 调度，且 `com.apple.expose.front.awake`（App Exposé）、`com.apple.expose.awake`（调度中心）和 `com.apple.showdesktop.awake`（显示桌面）均不受系统触控板独立开关关闭的影响。
- **TN3179 本地网络隐私规避**：遵循 Apple TN3179 建议，服务端刻意不注册 Bonjour `_http._tcp` 服务记录，仅使用普通 TCP `NWListener` 监听并依赖系统 `mDNSResponder` 解析 `.local`，从而避免 ad-hoc 签名应用触发本地网络隐私拒绝；同时自动识别 iPhone 个人热点 / USB 共享的 `172.20.10.x` 网段，在菜单栏弹窗中一键切换直连 IPv4，解决校园网或热点屏蔽 mDNS 的问题。

---

## 三、立即体验

1. 从 [GitHub Releases](https://github.com/Zou-Zhongyuan/AirTrackpad/releases/latest) 下载 `AirTrackpad-v1.0.0-macOS-arm64.zip` 解压放到「应用程序」（首次运行若提示未公证，终端执行 `xattr -cr /Applications/AirTrackpad.app` 后打开即可）；
2. 点击顶部菜单栏触控板图标，一次性授予「辅助功能」权限；
3. 用 iPhone 相机扫码打开网页后，点 Safari 底部「分享 → 添加到主屏幕」即可永久全屏使用。

完整源代码与交互演示主页已发布在 [GitHub](https://github.com/Zou-Zhongyuan/AirTrackpad) 与 [GitHub Pages](https://zou-zhongyuan.github.io/AirTrackpad/)，欢迎 Star、提 Issue 或 Fork 定制属于你自己的手势手感！
