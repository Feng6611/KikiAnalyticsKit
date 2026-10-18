# KikiAnalyticsKit 组件设计（PostHog）

状态：**已定稿，实现中（0.1.0）**。2026-10-18。范围只有组件本身；每个 App 的事件表各自单独设计，
放在 App 自己的 `Docs/Analytics.md`。实现落地后同步 `BUILD_SYSTEM.md` 和 `registry.yaml`。

## 0. 先拍板的事

1. **不能放进 Kiki_mackit。** `Kiki_mackit/AGENTS.md` 规定 Base Kit 不含网络、
   analytics 和产品状态。所以做成和 KikiCommerceKit 平级的独立包
   `KikiAnalyticsKit`；Base Kit 和 Commerce Kit 都不依赖它。
2. **Command Reopen 在 1.4.2 移除过 PostHog**（`8c0fd47` 接入，`a787ded` / `19fd542` 移除），
   没有写原因；现在的 `PRIVACY.md`、README 和 `PrivacyInfo.xcprivacy` 都承诺不收集 analytics。
   **当时为什么移除？** 组件设计不受这件事影响，但 Command Reopen 接入前要先说清楚。
3. **ArtWall `Docs/PaidAccess.md` 第 12 条是"No tracking"**，接入时要改写。
   ArtWall 还没有隐私政策，可以和埋点一起写。

## 已定决策（2026-10-18）

- 不弹窗征求同意；首期设置里不放关闭开关，隐私政策和 App Privacy 标签如实披露。
- SDK 自动采集只开生命周期事件和默认设备属性；不做 IP 地理定位、不开错误自动上报、不录屏。
- 匿名 ID 用 Kit 生成的安装 UUID，以后可直接作为 RevenueCat `app_user_id`。

## 1. 设计目标

- **调用只有一行**：`analytics.track(.wallpaperChanged(trigger: .manual))`。
  事件名、属性和频率都在 App 的事件枚举里定义好，调用点不拼字符串、不写去重逻辑。
- **Kit 只提供机制，App 决定意义**：怎么发送、怎么去重、附加哪些公共属性、隐私默认值都由 Kit 负责；
  有哪些事件、什么算一次价值，由 App 决定。这和 Commerce 的分工一致。
- **类型层面挡住隐私泄漏**：属性值没有接受任意 String 的入口。
- **没配置就零开销**：没有 token、`isEnabled = false` 或在测试里，都不初始化 SDK，也不发网络请求。
- **可测**：App 单测能直接断言"这个操作发了哪个事件、带了哪些属性"。

## 2. 包结构

```text
KikiAnalyticsKit/
├── KikiAnalytics          不含 SDK：事件协议、属性值、频率去重、公共属性、
│                          安装 ID、开关、SwiftUI 环境注入
├── KikiPostHog            posthog-ios（exact 版本）适配器，隐私配置锁死
└── KikiAnalyticsTesting   RecordingAnalyticsTransport + 断言辅助
```

```text
Product App ──► KikiAnalytics ◄── KikiPostHog ──► posthog-ios
     │
     └──► Kiki_mackit / KikiCommerceKit（与 AnalyticsKit 互不依赖）
```

- 只有 App 的 Composition import `KikiPostHog`；其余代码只 import `KikiAnalytics`，
  不接触 PostHog，以后换后端只需换一个 transport。
- Commerce 不 import Analytics。Paywall 事件由 App 观察 Commerce 的公开状态后发送。
- ArtWall 屏保这类扩展 target 不链接 AnalyticsKit。

## 3. App 怎么用

### 3.1 定义事件（每个 App 一个文件，就是它的事件表）

```swift
import KikiAnalytics

enum ArtWallEvent: KikiAnalyticsEvent {
    case onboardingCompleted(method: OnboardingMethod, durationMs: Int)
    case valueDay(changes: Int)
    case wallpaperChanged(trigger: ChangeTrigger)

    enum ChangeTrigger: String { case manual, automatic, previous, gallery }

    var name: String {
        switch self {
        case .onboardingCompleted: "onboarding completed"
        case .valueDay:            "value day"
        case .wallpaperChanged:    "wallpaper changed"
        }
    }

    var properties: KikiAnalyticsProperties {
        switch self {
        case let .onboardingCompleted(method, ms): ["method": .enum(method), "duration_ms": .int(ms)]
        case let .valueDay(changes):                ["value_bucket": .bucket(changes)]
        case let .wallpaperChanged(trigger):        ["trigger": .enum(trigger)]
        }
    }

    var frequency: KikiAnalyticsFrequency {
        switch self {
        case .valueDay: .oncePerLocalDay        // 当天第一次才发，Kit 负责去重和计数
        default:        .always
        }
    }
}
```

### 3.2 组装（只在 Composition 里出现一次）

```swift
import KikiAnalytics
import KikiPostHog

let analytics = KikiAnalytics(
    app: .init(id: "art_wall", channel: .appStore, storagePrefix: "artwall.analytics"),
    transport: .postHog(.fromInfoPlist()),      // token 缺失或是占位值 → 自动变成 no-op
    context: { ["entitlement_state": .enum(accessModel.analyticsState)] }
)
```

### 3.3 调用

```swift
// 控制器 / 模型：构造时注入
analytics.track(ArtWallEvent.wallpaperChanged(trigger: .manual))

// SwiftUI 视图：环境注入，不需要层层传参
@Environment(\.kikiAnalytics) private var analytics
Button("New Painting") { analytics.track(ArtWallEvent.wallpaperChanged(trigger: .manual)) }

// App 根视图注入一次
RootView().kikiAnalytics(analytics)
```

事件枚举可以加一个简短的扩展，调用点就能写 `.wallpaperChanged(...)`：

```swift
extension KikiAnalyticsTracking {
    func track(_ event: ArtWallEvent) { track(event as any KikiAnalyticsEvent) }
}
// analytics.track(.wallpaperChanged(trigger: .manual))
```

### 3.4 测试

```swift
let recorder = RecordingAnalyticsTransport()
let analytics = KikiAnalytics(app: .test, transport: .custom(recorder))
model.changeWallpaper()
XCTAssertEqual(recorder.names, ["wallpaper changed"])
recorder.assertNoProperty(containing: "com.apple")   // 隐私断言
```

## 4. 公开 API

```swift
// MARK: 事件

public protocol KikiAnalyticsEvent {
    var name: String { get }                          // object verb 小写，与官网契约一致
    var properties: KikiAnalyticsProperties { get }   // 默认 [:]
    var frequency: KikiAnalyticsFrequency { get }     // 默认 .always
}

public enum KikiAnalyticsFrequency: Sendable {
    case always
    case oncePerInstall                // 例：app first opened
    case oncePerLocalDay               // 例：value day；自动附加 active_day_index、days_since_first_open
    case oncePerSession(id: String)    // 例：paywall viewed，同一个 paywall 会话只计一次，不按 onAppear 计
}

// MARK: 属性值——没有接受任意 String 的入口

public typealias KikiAnalyticsProperties = [String: KikiAnalyticsValue]

public struct KikiAnalyticsValue: Sendable, Equatable {
    public static func `enum`<E: RawRepresentable>(_ v: E) -> Self where E.RawValue == String
    public static func enums<E: RawRepresentable>(_ v: [E]) -> Self where E.RawValue == String
    public static func int(_ v: Int) -> Self
    public static func bool(_ v: Bool) -> Self
    public static func bucket(_ count: Int) -> Self       // "0" "1_2" "3_9" "10_29" "30_plus"
    public static func durationMs(since start: Date) -> Self
    public static func sessionID(_ id: KikiAnalyticsSessionID) -> Self  // Kit 生成的随机 ID
}

// MARK: 入口

public protocol KikiAnalyticsTracking: AnyObject {
    @MainActor func track(_ event: any KikiAnalyticsEvent)
}

@MainActor
public final class KikiAnalytics: KikiAnalyticsTracking, ObservableObject {
    public init(app: KikiAnalyticsApp,
                transport: KikiAnalyticsTransportFactory,
                defaults: UserDefaults = .standard,
                clock: KikiAnalyticsClock = .system,
                context: @escaping () -> KikiAnalyticsProperties = { [:] })

    public func track(_ event: any KikiAnalyticsEvent)
    public func newSession() -> KikiAnalyticsSessionID     // paywall / onboarding 会话
    public func flush()                                     // 退出前调用

    @Published public var isEnabled: Bool                   // 程序开关，持久化在 App 前缀下；首期不在设置里露出
    public var installationID: UUID { get }
    public var firstOpenDate: Date { get }

    public static let disabled: KikiAnalytics               // 预览和测试用的 no-op
}

public struct KikiAnalyticsApp: Sendable {
    public var id: String                  // "command_reopen"，稳定、不本地化
    public var channel: Channel            // .appStore / .direct / .setapp，由 App 显式传入
    public var storagePrefix: String       // UserDefaults 键前缀，由 App 拥有，不可改名
    public var schemaVersion: Int = 1
}

// MARK: 传输层

public protocol KikiAnalyticsTransport: AnyObject {
    func send(name: String, distinctID: String, properties: [String: Any])
    func flush()
    func setOptedOut(_ optedOut: Bool)
}

public struct KikiAnalyticsTransportFactory {
    public static let none: Self
    public static func custom(_ t: KikiAnalyticsTransport) -> Self
    // KikiPostHog 里扩展：.postHog(KikiPostHogConfiguration)
}
```

### Kit 自动处理的事

| 事 | 行为 |
| --- | --- |
| 公共属性 | 每个事件附加 `app_id`、`app_version`、`build_number`、`distribution_channel`、`os_version`（只到 `macOS 15.4`）、`app_locale`、`schema_version`，再合并 App 的 `context()` |
| 首次打开 | SDK setup 后自动发 `app first opened`（每个安装一次）；老用户首次接入时标 `first_open_kind = analytics_rollout`（App 传入"是否老用户"的判断）。SDK 的 `Application Installed` 对老用户也会触发，看板里的安装数以 `app first opened` 的 `fresh_install` 为准 |
| 去重 | `oncePerInstall`、`oncePerLocalDay` 的状态存在 `storagePrefix` 下，跨重启有效；按本地日历计算日期。`oncePerSession` 只在内存里去重，会话随进程结束，不写 UserDefaults |
| 初始化时机 | 有 token 且已启用时，在 `KikiAnalytics` 创建时 setup SDK（生命周期事件需要从启动开始监听）；无 token 时永不 setup |
| 关闭 | `isEnabled = false` 后丢弃事件并调用 SDK opt-out；去重状态照常推进，重新打开后不会补发。首期设置里不放开关（2026-10-18 决定），接口保留 |
| 属性冲突 | App 属性不能覆盖公共属性键；Debug 下断言失败，Release 下丢弃该键 |
| Debug 日志 | Debug 构建把每个事件写进 `os.Logger`（subsystem = bundle ID），配合 `build_and_run.sh --telemetry` 查看 |

## 5. KikiPostHog 锁死的配置

App 不能修改以下配置：

| 项 | 值 |
| --- | --- |
| 核实版本 | posthog-ios **3.89.0**，发布于 **2026-10-03 01:04:34 UTC**；截至 2026-10-18，最新的已发布满两周的版本。以 `.build/checkouts/posthog-ios` 的源码及 macOS 编译为准 |
| `captureApplicationLifecycleEvents` | **true**。`Application Installed` / `Application Updated`：安装 integration 时立即比较持久化的 build，`NSApplication.didFinishLaunchingNotification` 也触发待发事件检查；无旧 build 为 Installed，build 改变为 Updated，同一进程只记录一次。`Application Opened` 来自 `NSApplication.didBecomeActiveNotification`；`Application Backgrounded` 来自 `NSApplication.didResignActiveNotification`（macOS 没有 didEnterBackground），前后台状态防重复 |
| `captureScreenViews`、`enableSwizzling`、元素点击自动采集 | 前两项在 macOS **均有可编译的配置属性**，均设 false。自动 screen 的 viewDidAppear swizzle 实现在 macOS 为 no-op；macOS 的推送 opened integration 可以使用 swizzling，因此不能笼统说 macOS 不支持 swizzling。`captureElementInteractions` / `captureSwiftUIElementInteractions` 仅 iOS / Mac Catalyst 编译，原生 macOS 无此属性和 integration |
| SDK 默认设备属性：静态上下文白名单 | **全部保留**：`$app_name`、`$app_version`、`$app_build`、`$app_namespace`、`$is_testflight`、`$is_sideloaded`、`$device_manufacturer`、`$device_model`、`$device_type`、`$device_name`、`$is_emulator`、`$is_ios_running_on_mac`、`$is_mac_catalyst_app`、`$os_name`、`$os_version`。实际键是 `$os_name`，不是 `$os`；设备名为型号分类而非用户主机名，SDK 的 `$os_version` 保留原始精度（Kit 的 `os_version` 只到主/次版本） |
| SDK 默认设备属性：动态上下文与 SDK 信息白名单 | **全部保留**：`$screen_width`、`$screen_height`（有 key window 所在屏幕时）、`$locale`、`$timezone`、`$network_wifi`、`$network_cellular`（reachability 存在时）、`$lib`、`$lib_version`。`$hinge_status` 只在支持 UIHinge 的 iOS 更新，原生 macOS 不产生 |
| SDK 事件构建附加属性白名单 | **全部保留**：`$is_identified`、`$process_person_profile`、`$geoip_disable`、`$recording_status`（macOS 为 disabled）、`$session_id`、`$sdk_debug_session_start`、`$sdk_debug_current_session_duration`、`$sdk_debug_pending_queue_size`（后三项在相应 session / queue 状态存在时）。以上三行合计 **31 个固定 `$` 键**，就是适配器 SDK 白名单；filter 同时强制匿名、禁建人物档案和 GeoIP 关闭 |
| 已关闭功能的条件属性（不属于默认白名单） | `buildProperties` 还可在调用方开启其他能力后附加 `$groups`、`$feature/<key>`、`$active_feature_flags`、`$set`、`$set_once`、`$screen_name`；identify 路径可附加 `$anon_distinct_id`。Kit 不开放这些调用，filter 全部删除（包括旧 SDK 缓存带来的 flags / groups）。`$device_id` 及 flags 请求的 `$anon_distinct_id` 在 `PostHogApi` 的 flags 请求体中，不是默认事件属性；`$window_id` 和 replay debug 属性为 iOS replay 路径，macOS 不产生 |
| `personProfiles` | `.never`，不调用 identify |
| Feature flags 预加载与 flag 事件、Session Replay、Surveys、错误采集 | `preloadFeatureFlags = false`、`sendFeatureFlagEvent = false`、`setDefaultPersonProperties = false`（仅关闭 flags 人物上下文，不影响设备事件属性）。`sessionReplay` 及其 integration 仅 iOS 编译；`surveys` 在 macOS 标记 unavailable，survey integration 也仅 iOS 安装，因此这两项在 macOS 不赋值就已关闭。SDK remote config 总会加载，`remoteConfig = false` 已是弃用 no-op；不等于启用 flags 预加载 |
| `getAnonymousId` | 在 macOS 可用，签名为 `(UUID) -> UUID`，忽略 SDK 参数，返回 Kit 的安装 UUID。SDK 只在没有已存匿名 ID 时调用它；适配器在 setup 返回后用 `config.storageManager` 的公开 setter 对齐已有 SDK 身份，不调用 identify。setup 内同步生命周期事件也由 beforeSend 强制使用 Kit 的 distinct ID |
| `flushAt` / `flushIntervalSeconds` | 20 / 900 |
| `setBeforeSend` | macOS 可用，在事件缓存/入队前同步执行。只放行"上述 31 个 SDK 默认属性白名单 + Kit 公共属性 + 本次事件及 context 声明过的键"；每次 capture 的临时声明标记在 filter 内删除，不跨事件累计。生命周期事件放行 SDK 白名单、Kit 公共属性和 SDK 自带的 `version` / `build` / `previous_version` / `previous_build` / `from_background`（只含版本号和是否从后台恢复，用来看升级路径和冷启动）。生命周期事件的 Kit 公共属性来自 transport 创建时的快照 |
| `$geoip_disable` | true（2026-10-18 决定不做 IP 地理定位）；PostHog 项目侧同时开启丢弃 IP |
| 错误/崩溃自动上报 | `errorTrackingConfig.autoCapture = false`，macOS 可编译且支持该 integration；同时 `errorTrackingConfig.exceptionSteps.enabled = false`，不维护错误步骤缓冲区 |
| 其他自动采集与开关持久化 | `capturePushNotificationSubscriptions = false`、`capturePushNotificationOpened = false`。`optOut = false`；Kit 已在自己的 storagePrefix 下保存开关，因此设置此 exact SDK 的 `@_spi(PostHogInternal) persistOptOut = false`，避免 SDK 旧开关覆盖 Kit 的状态；这是唯一使用的 SDK SPI，升级时必须复核 |
| 源码核实位置 | tag `3.89.0` 的 `PostHog/PostHogConfig.swift`、`PostHogContext.swift`、`PostHogSDK.swift`（`buildProperties` / `sessionDebugProperties` / `buildEvent`）、`PostHogStorageManager.swift`、`PostHogRemoteConfig.swift`、`PostHogApi.swift`、`AppLifeCycle/ApplicationLifecyclePublisher.swift`、`AppLifeCycle/PostHogAppLifeCycleIntegration.swift`、`ScreenViews/ApplicationScreenViewPublisher.swift`、`PostHogHingeStatusObserver.swift`；全部在本地 `.build/checkouts/posthog-ios` 读取核实 |

`KikiPostHogConfiguration.fromInfoPlist()` 读取 `KikiPostHogProjectToken` 和 `KikiPostHogHost`
（App 用被 ignore 的 xcconfig 填入）。token 为空、为占位值或不是 `phc_` 开头时返回 no-op。
另附一个脚本 `script/check_posthog_config.sh <app>`，供 App 的 archive 门禁使用：Release 缺 token 时失败。

PostHog 项目：所有 Mac App 共用一个项目，用 `app_id` 区分（与官网用 `site_id` 区分的做法一致）；
不和官网项目混用。

## 5A. 收入数据：RevenueCat 原生 PostHog 集成

RevenueCat 自带 PostHog 集成（Project settings › Integrations › PostHog），由服务端直接把订阅事件写进
PostHog，不需要自建 webhook。

- **事件**：initial purchase、trial started / converted / cancelled、renewal、cancellation、
  uncancellation、non-subscription purchase（lifetime）、expiration、billing issue、product change。
  带金额的事件统一换算成 USD，`currency` 保留原币种；毛收入还是扣佣金/税后的净收入在集成里选。
  每个事件还会更新人物属性 `rc_subscription_status`。
- **身份对齐**：客户端调用 `Purchases.shared.attribution.setPostHogUserID(<安装 UUID>)`，
  RevenueCat 会把它存成 `$posthogUserId` 属性，发到 PostHog 的事件就落在同一个 distinct ID 上。
  **不用改 RevenueCat 的 `app_user_id`**，已有的匿名用户和购买记录不受影响。没设置这个属性时，
  RevenueCat 退回用 `$RCAnonymousID:…`，就和 App 事件对不上了。
- **需要改 KikiCommerceKit**：`RevenueCatConfiguration` 增加一个可选的 `postHogUserID: String?`，
  `RevenueCatCommerceClient` 在 configure 之后调用 `setPostHogUserID`。Commerce 只收一个字符串，
  不依赖 AnalyticsKit；App 在 Composition 里把 `analytics.installationID` 传进去。属于跨包公开 API，
  要做跨厂商 review。
- **Sandbox**：集成里可以分别填生产和 sandbox 的 project key。建议 sandbox 指向开发项目，或者留空，
  避免测试购买混进生产数据。
- **人物档案**：客户端是 `personProfiles = .never`，但 RevenueCat 的服务端事件会给付费用户建档案
  （写 `rc_subscription_status`）。付费用户数量少，可以接受，看板里也正好能按订阅状态拆分。
- **不用的部分**：RevenueCat 的 paywall 事件只覆盖 RevenueCat Paywalls；Kiki 用自己的 paywall，
  这部分不开，paywall 事件由 App 自己发。
- **收入的事实源**：只看这些服务端事件，客户端的 `purchase result` 只用来看漏斗。

## 5B. PostHog 项目结构（建议，待确认）

PostHog 的层级是 组织 → 项目；项目之间不能联合查询，项目内用事件属性筛选。

| 层级 | 建议 | 理由 |
| --- | --- | --- |
| 组织 | 一个：kkuk | 计费和成员统一 |
| 项目 `Mac Apps` | 所有 Mac App 共用一个；能沿用旧的 `mac-app` 项目就沿用 | 跨 App 看板只能在同一个项目里做；一个 token、一个 RevenueCat 集成目标 |
| 项目 `Mac Apps Dev` | Debug 联调和 RevenueCat sandbox 事件 | 测试数据不进正式口径 |
| 项目 `Sites`（已有） | 官网，不动 | 身份模型不同（访客 vs 安装），经 App Store 也连不上，混在一起只会搞混口径 |
| 项目内分 App | 每个事件的 `app_id`，再按 `distribution_channel` 细分 | 不用付费的 Group Analytics；看板一个总览 + 每个 App 一个 |

注意：
- 启用 RevenueCat 集成后先核对它发来的事件里有没有自带 `app_id`（RevenueCat 自己的 app ID）。
  如果和 Kit 的 `app_id` 冲突，看板里 RevenueCat 事件按 `product_id` 或人物关联筛选，不要改 Kit 的键名。
- 如果套餐限制项目数量，`Mac Apps Dev` 可以不建：Debug 构建本来就不带 token，什么都不发。

## 接入状态（2026-10-18）

- PostHog project token：**未填**。各 App 的 `LocalSecrets.xcconfig` 里 `KikiPostHogProjectToken` 留空，由负责人填写；
  没有 token 时 Kit 不初始化 SDK、零请求。
- PostHog 项目：结构见 5B，尚未确认和创建。
- RevenueCat PostHog 集成：未启用，等 project key。KikiCommerceKit 的 `postHogUserID` 已在 main（`00f31b1`），未发版。
- App 接入：Command Reopen 已决定重新加回（其仓库 `docs/DecisionLog.md` D-012）；ArtWall 待接入。两个 App 的事件表都待定。

## 6. 推荐的共享事件名

Kit 不强制，但建议各 App 的事件表优先复用以下名字，跨 App 看板才能对齐。
是否使用、何时触发，在每个 App 的事件表里决定。

`app first opened`（Kit 自动发送）、`onboarding started`、`onboarding completed`、`value day`、
`paywall viewed`、`paywall action`、`purchase result`。

Kit 可以提供 `KikiStandardEvent` 枚举，把这几个事件的名字和属性键固定下来，App 直接用：

```swift
analytics.track(KikiStandardEvent.paywallViewed(session: s, source: PaywallSource.settings))
```

## 7. 每个 App 的事件表（另行设计）

每个 App 一份 `Docs/Analytics.md`，加一个与之一一对应的 `<App>AnalyticsEvent.swift`。表头固定：

| 事件 | 触发点（代码位置） | 频率 | 属性 | 回答的问题 |
| --- | --- | --- | --- | --- |

再加两段：本 App 的 `value day` 定义，和本 App 的"永不采集"清单。
Command Reopen 的清单至少包括其他 App 的名字、bundle ID、窗口标题和 URL。

## 8. 验证

- Kit 单测：公共属性、安装 ID 稳定性、三种频率的去重（跨重启、跨午夜、改时区）、分桶边界、
  关闭后零调用、无 token 时零 SDK 初始化、`beforeSend` 白名单。
- Kit 自带一个 Example App，Debug 下把事件打到控制台，用来检查调用手感。
- 首个 App 接入时用开发 PostHog 项目，每种事件回读一条，核对 schema 和 distinct ID。
- 工作区：`registry.yaml` 增加 `analytics-kit` 角色，`audit_dependencies.sh` 能识别它。
  新包有公开 API，按 `orchestrate-agent-work` 请另一家模型 review。

## 9. 推进顺序

1. 你确认第 0 节和本设计的 API 形状。
2. 实现 KikiAnalyticsKit 0.1.0（三个 target，加单测和 Example）。
3. ArtWall 写事件表，然后接入（用本地路径联调，同时写首版隐私政策）。
4. Command Reopen 写事件表，然后接入 App Store 版，同时改隐私承诺。
5. KikiCommerceKit 加 `postHogUserID`；在 RevenueCat 后台打开 PostHog 集成（这一步是后台操作，需要你授权或亲自做）。

## 不做

- 自动采集、Session Replay、Surveys、人物档案、跨 App 身份关联。
- `.trackOnAppear` 这类视图修饰符：视图出现不等于事件发生。
- 任意 String 属性值，以及 `track("name", ["k": "v"])` 这种字符串 API。
