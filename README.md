# paperclip-ios

Native iOS client for self-hosted [Paperclip](https://github.com/paperclipai/paperclip), pinned to Paperclip 2026.1005.0 (server commit `467125f`). Early stage: the API client is in place, screens come next.

## Layout

- `App/`: SwiftUI app.
- `Packages/PaperclipAPI/`: Swift package with the REST client, models, server URL handling and per-server key storage.
- `project.yml`: XcodeGen spec. Run `xcodegen generate` and open `PaperclipIOS.xcodeproj`.

## Servers

No server is built in. At sign-in you type your server URL; the app checks `GET /api/health` and warns when the server commit is not the pinned one. URLs are kept in app settings and board API keys in the Keychain, one per server. Tests use the placeholder host `paperclip.test`, and CI fails if shipped code contains a URL literal.

## Tests

- API client: `cd Packages/PaperclipAPI && swift test` (macOS) or the `xcodebuild test` step in `.github/workflows/ci.yml` (iOS simulator).
- App: `xcodebuild test -project PaperclipIOS.xcodeproj -scheme PaperclipIOS -destination 'platform=iOS Simulator,name=iPhone 16'`.

## Builds

Every push to `staging` or `main` publishes an unsigned `.ipa` as a pre-release on the Releases page. Sign it with your own certificate before installing.

## License

MIT
