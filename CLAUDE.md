# CLAUDE.md — paperclip-ios

What an agent needs before changing this repo. Read it whole once; it is short on purpose.

## What this is

A native iOS client for self-hosted [Paperclip](https://github.com/paperclipai/paperclip). It talks
to a Paperclip server **only through its REST API** and works with **any** server the user types in:
no server URL is hardcoded in code, config, fixtures or CI.

- Swift 5.9+ (language mode 5), SwiftUI, iOS 17+. No UIKit unless SwiftUI has no way to do it.
- Pinned to **Paperclip 2026.1005.0** (server commit `467125f`). The API is the one that version
  serves at `GET /api/openapi.json`.
- Open source (MIT), public repo. Treat every line, fixture and log as public.

## Working without a Mac

Agents work on a Linux VM. There is no Xcode, no Swift toolchain and no simulator here.

- The Xcode project is **generated** by XcodeGen from `project.yml`; `*.xcodeproj` is gitignored.
  New source folders, targets, packages and build settings go in `project.yml`, never in a project
  file.
- **CI on the GitHub macOS runner is the only compiler.** Push your branch, open the PR, and read the
  result:
  ```bash
  gh pr checks <pr> --watch
  gh run view <run-id> --log-failed      # compiler errors and failing tests
  ```
  A run takes about 6 minutes. Batch your fixes; do not push one-line guesses in a loop.
- Write code you can reason about without a compiler: small types, explicit types at API
  boundaries, no clever generics, no macros beyond `@Observable` and `#Preview`.
- Because you cannot run the app, every behaviour needs a test that CI runs. "It compiled in CI" is
  not done.

## Layout

```
App/                      SwiftUI app target (screens, view models, app wiring)
Packages/PaperclipAPI/    local SwiftPM package: API client + models (Foundation only)
Tests/                    app unit tests (PaperclipIOSTests)
project.yml               XcodeGen spec (source of truth for the project)
.github/workflows/ci.yml  build, test, unsigned .ipa
```

The package imports **Foundation only** (no SwiftUI, UIKit, Security) so it stays testable on its
own with `swift test`. Keychain, UI and app state live in the app target.

## API client rules

- REST only. No WebSocket in v1: the server's event socket does not accept board API keys. Refresh
  with `updatedSince` polling while a screen is open and pull to refresh.
- One `APIClient` with `async throws` methods, built on `URLSession`. The transport is injectable
  so tests stub it (a `URLProtocol` stub or a protocol over `data(for:)`).
- Models are **hand-written `Codable` structs**, one per resource, checked against
  `GET /api/openapi.json` of 2026.1005.0 and against recorded JSON fixtures. No OpenAPI generator:
  the spec misses routes we use and a generator adds a build plugin we cannot run locally.
- Decode leniently: unknown enum values map to an `.unknown(String)` case, optional fields stay
  optional. A new server field must never crash the app.
- Dates are ISO 8601 with fractional seconds; use one shared `JSONDecoder` configured for that.
- Errors: one `APIError` enum (`.unauthorized`, `.notFound`, `.server(status:body:)`,
  `.decoding`, `.transport`). A 401 means the key expired or was revoked: send the user to
  sign-in for that server, never retry with the same key.
- Endpoints the app may call are listed in the plan (§2, TUD-1024). Using another endpoint is a
  design change: ask the tech lead first.
- Paperclip upgrade = one task: diff `openapi.json`, fix models and fixtures, bump the pin here and
  in `README.md`.

## Auth and accounts

- Sign-in is the Paperclip **CLI device flow**; the app never asks for a password.
  1. `GET /api/health` on the URL the user typed. Warn (do not block) if the `commit` is not the
     pinned one.
  2. `POST /api/cli-auth/challenges` with `{command, clientName: "Paperclip iOS", requestedAccess: "board"}`
     → `{id, token, boardApiToken, approvalUrl, pollPath, expiresAt}`. `boardApiToken` is the key;
     it only works once the user approves.
  3. Open `approvalUrl` in `ASWebAuthenticationSession`; poll `GET /api/cli-auth/challenges/:id?token=…`
     until `status` is `approved` (then keep `boardApiToken`) or `cancelled` / `expired`. The poll
     response never contains the key.
  4. `GET /api/cli-auth/me` for the user and companies. Sign-out: `POST /api/cli-auth/revoke-current`,
     then delete the local key.
- Several servers ("accounts") at once, switched in Settings, each with its selected company.
  Account metadata (id, base URL, user name, selected company, key expiry) is stored as JSON in
  the app's Application Support folder. The **API key lives only in the Keychain**: one generic
  password item per account, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no explicit
  access group (the app is re-signed by a third party; a fixed group breaks).
- Keys expire (30 days by default): warn before expiry and re-run the flow. The server does not
  report a key's expiry, so the app counts 30 days from the challenge's `approvedAt` and warns
  3 days before.
- Code: `AccountStore` (accounts, current account, its `APIClient`; every authenticated call goes
  through `AccountStore.call` so a 401 marks the account "needs sign-in"), `SignInFlow` (device
  flow state machine), `ApprovalPresenter` (`ASWebAuthenticationSession`, faked in tests). All
  logging goes through `AppLog`; tests capture it to prove no key or token is logged.
- **Never log, print, persist outside the Keychain, or put in an error message** an API key or the
  device-flow token. Any request logging redacts the `Authorization` header.

## Screens and refresh

- Tab bar: **Today · Inbox · Tasks · Me** (`AppTab`). Task detail is a pushed screen, not a tab.
- Every list screen has a view model (`@MainActor @Observable`) that exposes one
  `LoadState<Value>`: `loading`, `loaded`, `empty`, `error(message)`, `needsSignIn`. Every call goes
  through `AccountStore.call`, so a 401 becomes `needsSignIn` and the account goes to sign-in.
- `refresh()` is a full fetch (screen appears, pull to refresh). `poll()` asks only for changes:
  `updatedSince` = the newest `updatedAt` already loaded (the server's clock, not the device's),
  merged by issue id. A failed poll keeps the rows on screen; a 401 still flips to `needsSignIn`.
- `Poller` calls `poll()` every 15 s from the screen's `.task`, so it stops when the screen goes
  away. Tests inject its `sleep`.
- Inbox: one fetch of `touchedByUserId=me&inboxArchivedByUserId=me`; the segments Unread
  (`isUnreadForMe`), Mine (assigned to or created by me) and All filter it locally. New comments
  bump an issue's `updatedAt`, so the delta poll sees new replies. Read or archive done in another
  client shows up on the next full fetch.
- Today: "Needs you" = attention items of kind interaction, approval and review
  (`GET /companies/:id/attention`) plus my open tasks; "New replies" = unread threads
  (`unreadForUserId=me`), at most 10, preview = first line of the newest comment not written by
  me (`GET /issues/:id/comments?limit=5`); pulse = running agents and blocked tasks from
  `GET /companies/:id/dashboard` plus tasks completed today. A failed pulse hides only the pulse.
  Until task detail exists, cards open the issue in the web UI.

## Tests

- New tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). Existing XCTest stays.
- Test first: the failing test lands in the same PR as the fix or feature.
- No network in tests. API tests decode recorded fixtures from the package's test resources and
  run against the stubbed transport.
- Fixtures are recorded from a real 2026.1005.0 server and **scrubbed** before commit: host becomes
  `paperclip.test`, keys and tokens become `pcp_board_TEST`, real names and emails become fake ones.
  Never commit our server's URL or real data.
- Keychain and account-store code sits behind a protocol; tests use an in-memory fake.
- UI: view models are tested as plain types. UI tests (XCUITest) only for the main flows, added
  when a flow exists.

## Branches, PRs and CI

- Branch from `staging`, PR into `staging`. **Nothing merges into `main`** until the board approves
  the first production launch. Both branches are protected: PR required, `gate` is the one required
  check, squash merge, linear history.
- Conventional Commits, scope optional: `feat(api): decode issue list`. PR description says what
  changed and how CI proves it; no internal task ids or agent names.
- CI (`ci.yml`, `macos-latest`): generate the project, build and run unit tests on an iPhone
  simulator for every PR and push. Changes to `ci.yml` or `project.yml` targets are reviewed by the
  tech lead.
- No new dependency (SwiftPM package, Homebrew tool in CI) without tech-lead approval.
- No secrets in this repo, ever. CI needs none until signing (later, via GitHub Environments).

## Release

- Every push to `staging` or `main` builds an **unsigned `.ipa`** (`CODE_SIGNING_ALLOWED=NO`),
  uploads it as the `Paperclip-unsigned-ipa` artifact and publishes it as a GitHub pre-release
  `build-<run number>` (a stable download link). The board signs it and installs it.
  ```bash
  gh run download <run-id> -n Paperclip-unsigned-ipa
  ```
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` when a build goes to the
  board.
- Out of scope until there is an Apple Developer account: push notifications, signing in CI,
  TestFlight.
