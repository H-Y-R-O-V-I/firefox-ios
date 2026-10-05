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

## HYROVI One and Shared Tabs

The Firefox tab tray keeps normal and private Firefox tabs and replaces the
former synced-tabs panel with a HYROVI-native Shared Tabs panel.

The HYROVI panel now provides:
- HYROVI One PKCE sign-in via hyrovi-browser://auth/callback
- encrypted access-token storage in the iOS Keychain
- live Shared Tabs grouped separately from regular synced tabs
- DOM-state streaming for live tabs instead of video/screen streaming
- click, input, key and scroll actions sent back to the host device
- One browser-sync tabs grouped by device
- synced URLs opening as normal Firefox tabs
- pull-to-refresh, account status and sign-out
- direct access to HYROVI One for device/account management

The HYROVI source files live in firefox-ios/Client/HYROVI/. They are added
only to the generated HYROVI development project by
scripts/hyrovi/make-dev-project.rb, keeping Mozilla's original
Client.xcodeproj free of HYROVI-only file references.

Verified for Build 2 on 2026-10-05:
- complete arm64 iPhone build succeeds with an iOS 15 deployment target
- bundle: com.hyrovi.browser.ios
- version: 158.1
- build: 2
- IPA validates in the HYROVI App System and is published to its IPA Queue
