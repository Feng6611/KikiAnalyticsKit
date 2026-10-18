# KikiAnalyticsKit

- Work only inside this independent Git repository.
- KikiAnalytics owns mechanisms; apps own product events and their meaning.
- No product-specific events, UI surfaces, or Settings toggle.
- No Kiki_mackit or KikiCommerceKit dependency; core has no third-party dependency.
- Only KikiPostHog imports PostHog. Pin its exact reviewed release.
- Privacy defaults in Docs/Design.md section 5 are locked, not host configuration.
- No identify, arbitrary-string property factory, replay, surveys, GeoIP, or error capture.
- SDK lifecycle events and default device properties stay enabled.
- SDK identity must be the Kit's installation UUID, never hardware/account identity.
- Keep installation, enablement and dedupe keys under the host's stable storagePrefix.
- Tests must remain offline and must never call PostHogSDK.setup.
- KikiAnalyticsTesting is for test targets; it imports XCTest.

Verification from the Git root:

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/kikianalytics-cache/clang
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/kikianalytics-cache/swiftpm
export CFFIXED_USER_HOME=/private/tmp/kikianalytics-home
swift build
swift test
swift build -c release
swift test -c release
git diff --check
```
