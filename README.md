# KikiAnalyticsKit

Optional, anonymous analytics for macOS 13+. Swift tools 5.9; no dependency on
Kiki_mackit or KikiCommerceKit.

- `KikiAnalytics`: typed events, safe property factories, installation identity,
  install and local-day deduplication, and SwiftUI environment injection. No SDK dependency.
- `KikiPostHog`: PostHog 3.89.0 adapter with locked privacy defaults.
- `KikiAnalyticsTesting`: recording transport and XCTest privacy assertions. Test targets only.

```swift
import KikiAnalytics
import KikiPostHog

enum AppEvent: KikiAnalyticsEvent {
    case taskCompleted
    var name: String { "task completed" }
}

// Create once in the app's main-actor composition root.
let analytics = KikiAnalytics(
    app: .init(id: "my_app", channel: .appStore, storagePrefix: "myapp.analytics"),
    transport: .postHog(.fromInfoPlist()),
    isExistingUser: { /* app-owned migration check */ false }
)
analytics.track(AppEvent.taskCompleted)
// RootView().kikiAnalytics(analytics)
```

Set `KikiPostHogProjectToken` and optionally `KikiPostHogHost` in the host's Info.plist.
Missing, placeholder, or invalid tokens create no transport. Use `KikiAnalytics.disabled`
for previews. `isEnabled` is persisted; apps do not expose a Settings toggle in 0.1.0.
An initially disabled instance never constructs the SDK until enabled.

The Kit sends `app first opened` at initialization, once per installation, before app
events. Existing users get `first_open_kind = analytics_rollout`; others get `fresh_install`.
Disabled/unconfigured events advance dedupe state and are never backfilled. Daily
counters are per event: `active_day_index` starts at 1; `days_since_first_open` starts
at 0. Local civil dates remain deduplicated when a time-zone change revisits a date.
Keep `storagePrefix` stable. Sessions are Kit-generated UUIDs; reuse one for a workflow.

SDK lifecycle events and default device properties are enabled. GeoIP, error capture,
screen capture, replay, surveys, flag preload, and person profiles are disabled. No
identify calls. Hosts own privacy disclosure and the PostHog project's IP discard setting.
See [the design](Docs/Design.md) for the source-verified SDK allowlist and platform details.
Use `script/check_posthog_config.sh /path/to/My.app` as an archive token gate.

```swift
import KikiAnalyticsTesting

let recorder = RecordingAnalyticsTransport()
let analytics = KikiAnalytics(
    app: .init(id: "test", channel: .direct, storagePrefix: "test.analytics"),
    transport: .custom(recorder),
    defaults: UserDefaults(suiteName: "MyIsolatedTests")!
)
analytics.track(AppEvent.taskCompleted)
XCTAssertEqual(recorder.names, ["app first opened", "task completed"])
recorder.assertNoProperty(containing: "com.apple")
```

Verify with `swift build`, `swift test`, `swift build -c release`,
`swift test -c release` (reserved-key drop path), and `git diff --check`.
Tests never initialize PostHog or send network requests.
