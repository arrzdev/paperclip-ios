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
UITests/                  XCUITest screen tour (PaperclipIOSUITests)
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
  client shows up on the next full fetch. Search: typing filters loaded titles at once; after a
  300 ms pause (`SearchDebounce`, run from `.task(id: searchText)` so a keystroke cancels it) the
  same inbox query plus `q` replaces the local filter; segments and swipes still apply; clearing
  needs no request.
- Tasks (`TasksModel`): the whole company (`GET /companies/:id/issues`), never the inbox
  filters. Status picker (`TaskStatusFilter`, default Open = backlog, todo, in_progress,
  in_review, blocked) and assignee picker (`TaskAssigneeFilter`: Anyone, Me = `assigneeUserId=me`,
  an agent = `assigneeAgentId`; agents from `GET /companies/:id/agents`, terminated left out). A
  filter change or pull to refresh refetches from the first page; search uses `SearchDebounce`
  and `q` and stays on for refresh and paging. Pages of 50 (`limit`, `offset`), "load more"
  until a short page; a failed page keeps the rows (`pageError`). Sections by project name
  (`GET /companies/:id/projects`), then "Other project" (not in the list, e.g. archived), then
  "No project"; rows keep the server order. A failed project fetch only loses the names. No
  polling: it is a look-up screen. Never log the search text.
- Task detail: one route, `TaskRoute(issueID:)`, pushed from every list (`.navigationDestination`
  in each tab's `NavigationStack`). `TaskDetailModel` needs the task and its thread; documents,
  attachments, live runs, agents and mark-read are extras whose failure never hides the task.
  The thread is oldest first (`order=asc`); `poll()` refetches the task and live runs and asks
  only for comments `after` the last id (a single task has no `updatedSince`). Opening marks the
  task read, and so does a poll that brings new comments. Pickers change the task at once and roll
  back on error; an assignee change sends both `assigneeAgentId` and `assigneeUserId` (one null).
  Review bar only on `in_review` / `done`; Re-open needs a non-empty comment (`status todo` +
  `comment` in one `PATCH`).
- Composer (`CommentComposer`): the draft (text + pending photo) is kept per account and task in a
  `DraftStore` (files in Application Support, in-memory in tests) and survives leaving the screen.
  A photo uploads first (`POST /companies/:cid/issues/:iid/attachments`, multipart field `file`),
  then the comment sends with its `attachmentIds`. A failure keeps the draft and offers Retry;
  Retry does not upload the same photo twice and reuses the comment's `clientRequestId`, so the
  server never posts it twice. Never log the draft text or image bytes.
- Today: "Needs you" = attention items of kind interaction and review
  (`GET /companies/:id/attention`), then pending approvals newest first
  (`GET /companies/:id/approvals?status=pending`, card "Approval: <title>"), then my open tasks; "New replies" = unread threads
  (`unreadForUserId=me`), at most 10, preview = first line of the newest comment not written by
  me (`GET /issues/:id/comments?limit=5`); pulse = running agents and blocked tasks from
  `GET /companies/:id/dashboard` plus tasks completed today. A failed pulse hides only the pulse.
  Until task detail exists, cards open the issue in the web UI.
- Requests (issue thread interactions, `GET /issues/:id/interactions`, pending only): Today pairs
  each attention item of kind interaction with its interaction (`subject.id`, one fetch per task);
  Task detail shows them in the thread by `createdAt`. `InteractionCard.action` is `.confirm`
  (`request_confirmation` without `toolAction` / `secretProposal`), `.answer` (`ask_user_questions`,
  at most 20 questions of mode single or multi, form = `QuestionForm`) or `.openInWeb` (anything
  else, never a crash). `RequestActions` (shared) hides the card at once and shows a 5 s undo
  toast; the request (`POST …/interactions/:iid/{accept,reject,respond}`) is sent only when the
  toast ends, the screen goes away or another action starts. Undo sends nothing. A failure
  brings the card back with the error; a 409 means it was already answered and the card stays
  gone. Never log a reject reason or an answer.
- Approval detail: one route, `ApprovalRoute(approvalID:)`, pushed from Today (each tab's
  `NavigationStack` has its `.navigationDestination`). `ApprovalDetailModel` needs the approval
  (`GET /approvals/:id`) and its comments (oldest first); agents (requester name) are an extra.
  `Approval.title` = payload `title ?? summary ?? recommendedAction ?? type`; `summaryFields` =
  the simple top-level payload fields. Decisions follow the server: Approve / Reject on `pending`
  or `revision_requested`, Ask for changes on `pending` only; each sends its optional note as
  `decisionNote` (`POST /approvals/:id/{approve,reject,request-revision}`). Never log a note.
- New task: one `NewTaskModel` per account and company, owned by `HomeView` and shared by the
  New task sheet (floating **+** on Today, Inbox and Tasks; on Inbox and Tasks it moves into the
  navigation bar from the accessibility text sizes up, `NewTaskButtonPlacement`, so rows never
  rest half hidden under it) and the Today bar "Message <name>…".
  One text field: `NewTaskText` splits it (first line = title, rest = description); a title is
  required, no priority, labels or blockers. Assignee chip = agents from
  `GET /companies/:id/agents`; project chip = `GET /companies/:id/projects` (default none, a failed
  fetch only empties it). Send = `POST /companies/:id/issues` with `status: todo` and an
  `idempotencyKey` kept in the draft until success (a retry replays, never a second task), then
  the photo uploads to the new task, then the task opens. A failed upload keeps the photo and
  Retry uploads only. The draft lives in the `DraftStore` under `NewTaskModel.draftKey(companyID:)`.
- Default assignee (`DefaultAssigneeStore`, one JSON file in Application Support, not the
  Keychain): the last agent the user gave a task to, per account and company; first use, or a
  stored agent that is gone or terminated, = the agent with role `ceo` (`DefaultAssignee.resolve`).
  Picking in the chip changes it only once the task is created.
- Me → Accounts (`AccountsModel`, shared by the Me tab and the quick switcher sheet opened from
  the Today title): every server with its user and companies (`GET /companies` with that
  account's own key), a "Needs you" badge per account and company = `inbox` of
  `GET /companies/:id/sidebar-badges`, polled every 15 s (badges only; a poll with the same counts writes nothing, so the list is not
  redrawn). A 401 marks only that
  account; a signed-out account is never called; a failed badge keeps the last count. Tap a
  company = `switchTo(accountID:companyID:)` (both persisted; `HomeView` is keyed by account and
  company, so Today reloads). Swipe a server: Sign out (`AccountStore.signOut`, key deleted, server
  stays to sign in again) or Remove. No change to `AccountStore` / `SignInFlow` for this screen.
- Me → More (read only, spec §3; Agents live here, not in a tab). `MoreModel` loads the company
  (`GET /companies/:id`) for its prefix; `WebLink` builds "Open in web" pages
  (`/<prefix>/…`) for everything the app cuts (company settings, secrets, tool connections,
  plugins, skills, routines, org chart, hire agent) and for each agent (`agents/<urlKey>`).
  - Agents (`AgentsModel`): `GET /companies/:id/agents` (terminated left out) plus
    `GET /companies/:id/live-runs` (an extra: a failure only loses the runs), polled every 15 s.
    Agent detail (`AgentDetailModel`, `AgentRoute`): `GET /agents/:id`, its live run; Pause unless
    paused / terminated / pending approval, Resume only when paused
    (`POST /agents/:id/{pause,resume}`); the server's answer replaces the agent, an error (a 409
    for a broken reporting chain) keeps it and shows the reason.
  - Run log (`RunLogModel`): `GET /heartbeat-runs/:id/log` in pages of `RunLogModel.pageBytes`
    from offset 0; `content` is NDJSON `{ts, stream, chunk, seq}` (`RunLog.parse`, lenient per
    field; a line cut at a page end is carried to the next page). Load more = `nextOffset`; a live
    run polls on from the end; a 404 = no output yet (`empty`). Never log the log text.
  - Activity (`ActivityModel`): `GET /companies/:id/activity?limit=100`, actor name (agents are an
    extra), humanised `action` plus the task identifier and title; issue events open the task.
  - Approvals history (`ApprovalsHistoryModel`): all statuses, newest first, opens `ApprovalRoute`.
  - Goals (`GoalsModel`): `GET /companies/:id/goals` as a tree in server order (`GoalRow.depth`);
    a missing parent puts the goal at the root, a cycle never hides or repeats a goal.
  - Costs (`CostsModel`): `GET /companies/:id/costs/summary` → `CostLine` ("$12.34 of $50.00 ·
    25%", or "No budget" when the budget is 0).

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
- UI-test mode (Debug only): the launch argument `-uiTestFixtures` signs in one fake account on
  `paperclip.test` and answers every request from the package fixtures (`FixtureMode`,
  `FixtureRoutes`; bundled as `Fixtures/`, excluded from Release). `-uiTestDark` forces dark mode.
  A screen that calls a new endpoint needs a route there. `ScreenTourUITests` walks Today, Inbox,
  Tasks, Me → Accounts and Me → More at default size, AX5 and dark, keeps a screenshot of each
  screen and runs `performAccessibilityAudit()` (an audit that timed out, or ran while the screen
  moved, runs once more and only that run counts; after a timeout that run checks one audit type
  at a time). `UITests/AccessibilityBaseline.json` holds the
  issue kinds already known per screen (kinds, not counts: findings vary between runs); a new kind
  on a screen fails. The Dynamic Type kind, known for a screen in one variant, counts in all three
  (the audit reports it unevenly). Contrast issues of elements under the tab, navigation or Today
  message bar are logged as `covered` and do not fail; their other issues count. Fixed a kind on a screen → remove it; never add one to hide
  a regression. CI job `ui-test` uploads `Paperclip-ui-screenshots`
  (screenshots, `audit-report.md`, test summary) and `Paperclip-ui-xcresult`.

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
