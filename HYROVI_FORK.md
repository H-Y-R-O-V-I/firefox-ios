# HYROVI Firefox iOS Fork

Base: Mozilla mozilla-mobile/firefox-ios

HYROVI development product uses the upstream Fennec scheme so Mozilla's
Firefox, FirefoxBeta, and FirefoxStaging configurations remain untouched.

Current HYROVI identity:
- Product: HYROVI Browser
- Main bundle: com.hyrovi.browser.ios
- URL scheme: hyrovi-browser
- App group: group.com.hyrovi.browser.ios
- Development team: VTZMACGB4B

The fork intentionally preserves Firefox's browser architecture, tabs, private
browsing, downloads, password management, extensions/targets, and WebKit engine.
HYROVI One and Shared Tabs are added as browser features on top.

## Development device build

Run: ruby scripts/hyrovi/make-dev-project.rb

This generates firefox-ios/HYROVIClient.xcodeproj with the shared scheme
HYROVI Browser Dev.

The generated development project keeps the Firefox main browser and its
internal Sync/Localizations frameworks, while removing only optional app
extension dependencies for local device signing:

- CredentialProvider
- NotificationService
- ShareTo
- WidgetKitExtension
- Sticker
- ActionExtension

It also disables Mozilla/Apple restricted target capabilities for the local
personal-team build and uses Client/Entitlements/HYROVIDev.entitlements.
This does not modify the upstream Client.xcodeproj.

Verified on 2026-10-05:
- upstream bootstrap succeeds
- upstream Fennec unsigned build succeeds
- HYROVI Browser Dev unsigned build succeeds
- HYROVI Browser Dev signed build succeeds for team VTZMACGB4B
- signed bundle: com.hyrovi.browser.ios
