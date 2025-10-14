## Quick orientation

This repository implements a Telegram bot that watches iOS App Store releases and notifies subscribers. The codebase is split into three logical modules:

- `ReleaseInformerBot` (executable): main bot logic, Telegram handlers, Vapor app scaffolding — see `Sources/ReleaseInformerBot/configure.swift` and `Sources/ReleaseInformerBot/entrypoint.swift`.
- `ReleaseWatcher` (service): background watcher that iterates subscriptions and sends notifications — see `Sources/ReleaseWatcher/ReleaseWatcher.swift`.
- `Shared` (library): models and persistence helpers (CouchDB) — see `Sources/Shared/Managers/DBManager.swift` and `Sources/Shared/Models/Subscription.swift`.

Read these files first to understand the end-to-end flow.

## Big-picture data flow

1. User sends command to the Telegram bot (handled by `BotHandlers` in `Sources/ReleaseInformerBot/TGBot/BotHandlers.swift`).
2. Handlers call `DBManager` (`Sources/Shared/Managers/DBManager.swift`) to create/list/delete `Subscription` documents in CouchDB.
3. `ReleaseWatcher` periodically fetches all subscriptions (`getAllSubscriptions()`), queries the iTunes API via `SearchManager` (`Sources/Shared/Managers/SearchManager.swift`) and updates subscriptions with new versions.
4. When a new version is detected, `ReleaseWatcher` uses the `TGBot` instance (set in `configure.swift` via `BotActor`) to send formatted HTML messages.

Key integration points: `DBManager` <-> CouchDB, `SearchManager` <-> iTunes API (https://itunes.apple.com), `AsyncHttpTGClient` <-> Telegram API.

## Concurrency & runtime patterns to keep in mind

- Actors are used heavily for thread-safety: `DBManager`, `SearchManager`, `ReleaseWatcher`, `BotActor`. Prefer `async/await` and actor isolation when changing shared state.
- `ReleaseWatcher` uses two `DispatchSourceTimer`s: a 5-minute `timer` for bulk runs and a 2-second `appCheckTimer` that processes a queue; it enforces small delays (2s) between individual chat notifications.
- The `entrypoint` contains commented-out code for attempting to install NIO as the global executor — be cautious if enabling it as it can change shutdown behavior.

## Persistence and DB conventions

- Database name: `release_bot` (hard-coded in `DBManager`).
- `DBManager.setupIfNeed()` will create the DB and add a design doc with two views: `by_bundle` and `by_chat`. The design doc id is `_design/list`.
- `Subscription` maps CouchDB keys with coding keys (bundle ID stored as `bundle_id`) — see `Sources/Shared/Models/Subscription.swift`.
- When adding versions, the project keeps the last 5 versions (see `DBManager.addNewVersion(...)`).

If you change the CouchDB credentials/host you must update `fileprivate let couchDBClient = CouchDBClient(...)` inside `DBManager.swift`.

## Bot & Telegram specifics

- Bot token is read from environment variable `apiKey` in `configure.swift`.
- The project uses `SwiftTelegramSdk` and a custom `AsyncHttpTGClient` (`Sources/ReleaseInformerBot/TGBot/AsyncHttpTGClient.swift`) which:
  - Defaults to multipart/form-data for most requests.
  - Limits response body reads to ~1MB for Telegram responses.
  - Throws a descriptive `BotError` when Telegram returns ok=false.
- Messages use HTML parse mode; handlers build HTML strings (see `BotHandlers.makeSearchResultsMessage` and `makeListMessage`). Preserve HTML encoding when editing messages.

## Search & iTunes quirks

- `SearchManager` performs HTTP GETs against the iTunes Search/Lookup APIs and contains a `processJSONString(_:)` sanitiser that:
  - Escapes control characters inside JSON strings
  - Replaces non-breaking spaces
  This behaviour exists because the iTunes API sometimes returns characters that break `JSONDecoder`. If you modify parsing, keep this sanitiser or add robust tests.

## How to run, build, and test

- Build: `swift build`
- Run locally: set the Telegram token and run the executable:

```bash
export apiKey="<YOUR_TELEGRAM_BOT_TOKEN>"
swift run
```

- Tests: `swift test` (tests use `Application.make(.testing)` from VaporTesting; see `Tests/ReleaseInformerBotTests/ReleaseInformerBotTests.swift`).

Notes: CouchDB must be reachable for the app to initialize successfully; `DBManager.setupIfNeed()` will try to create DB and views on startup and will exit the process on failure (see `configure.swift`).

## Common change patterns & examples

- Adding a new bot command: implement a handler in `BotHandlers` and register it from `addHandlers(bot:)`.
- To send a message from background code: obtain the `TGBot` via `BotActor` (see `configure.swift`) and call `bot.sendMessage(...)` from an async context.
- To add a new view or query in CouchDB: add the JavaScript map to the design document in `DBManager.setupIfNeed()` and ensure any changes keep existing docs compatible.

## Files to inspect when debugging

- `Sources/ReleaseInformerBot/configure.swift` — initialization order (DB -> bot -> watchers -> routes)
- `Sources/Shared/Managers/DBManager.swift` — DB access patterns and CouchDB client usage
- `Sources/ReleaseWatcher/ReleaseWatcher.swift` — timers, run loop, and notification flow
- `Sources/ReleaseInformerBot/TGBot/*` — bot client, handlers, and HTTP client

## Quick tips for agents

- Preserve actor isolation when editing shared state.
- Respect the 2s sleeps used to rate-limit notifications in `ReleaseWatcher` and `BotHandlers` — removing them may trigger API rate limits.
- When modifying message text, keep HTML tags and avoid unescaped user content.
- Add unit tests for parsing changes in `SearchManager.processJSONString(_:)` when touching JSON handling.

If anything here looks incomplete or you want more examples (e.g., an example test or a short diagram), tell me which area to expand. 
