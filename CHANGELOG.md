# Changelog

## 0.1.1 - 2026-10-21

### Fixed

- `KikiPostHogConfiguration` treats a blank host (an empty build setting) as the default host.

## 0.1.0 - 2026-10-18

### Added

- Product-neutral KikiAnalytics, KikiPostHog, and KikiAnalyticsTesting libraries.
- Typed property factories, installation UUID, common context, automatic first-open
  classification, persistent install/day deduplication, in-memory session deduplication, and SwiftUI injection.
- Lazy transport construction, persistent enablement, reserved-property protection,
  and Debug event logging.
- PostHog 3.89.0 (2026-10-03), locked anonymous privacy configuration and event allowlist;
  lifecycle events keep the SDK version and launch fields.
- Offline tests, a recording transport with XCTest privacy assertions, and an archive token gate.
