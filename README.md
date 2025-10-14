# Release Informer Bot for Telegram

A Telegram bot that monitors iOS App Store releases and sends notifications to subscribers when new versions are available. Built with modern Swift using the Vapor framework for robust server-side development.

## How It Works

The Release Informer Bot provides a comprehensive subscription system for iOS app release notifications:

1. **App Discovery**: Users can search for apps using the `/search <app name>` command, which queries the iTunes Search API
2. **Subscription Management**: Users subscribe to specific apps using `/add <bundle_id>` and manage their subscriptions with `/list` and `/del <bundle_id>`
3. **Release Monitoring**: A background watcher checks all subscriptions every 5 minutes using the iTunes API to detect new versions
4. **Smart Notifications**: When a new version is detected, the bot sends formatted notifications to all subscribed users with release details including version number, release notes, and App Store link
5. **Data Persistence**: All subscriptions are stored in CouchDB with efficient indexing for fast lookups by bundle ID and chat ID

### Available Commands

- `/start` - Show welcome message with inline keyboard
- `/help` - Display help information
- `/search <app name>` - Search for apps in the App Store
- `/add <bundle_id>` - Subscribe to notifications for an app
- `/del <bundle_id>` - Unsubscribe from an app
- `/list` - Show your current subscriptions

## Key Features & Architecture

### ✨ Good Parts

- **Modern Swift Concurrency**: Built with async/await and actors for safe concurrent operations
- **Modular Architecture**: Clean separation with three modules:
  - `ReleaseInformerBot`: Main bot logic and Telegram handlers
  - `ReleaseWatcher`: Background monitoring service
  - `Shared`: Common models and database management
- **Robust Monitoring**: Automated release checking with intelligent rate limiting and error handling
- **Scalable Storage**: CouchDB integration with optimized views for efficient queries
- **Production Ready**: Comprehensive logging and error handling
- **Real-time Notifications**: Instant notifications with rich formatting including release notes
- **Resource Management**: Intelligent memory management with version history limits (5 versions per app)

### 🏗️ Technical Architecture

- **Server Framework**: Vapor 4.x for high-performance HTTP server
- **Concurrency**: Swift's native actor system for thread-safe operations  
- **Database**: CouchDB with custom views for efficient data access
- **External APIs**: iTunes Search/Lookup API for app metadata
- **Deployment**: Flexible for local development and production

## Dependencies

The project uses carefully selected, production-grade dependencies:

### Core Dependencies
- **[Vapor](https://github.com/vapor/vapor)** `4.110.1+` - Server-side Swift web framework
- **[Swift NIO](https://github.com/apple/swift-nio)** `2.65.0+` - Non-blocking networking foundation
- **[SwiftTelegramSdk](https://github.com/nerzh/swift-telegram-sdk)** `3.8.0+` - Telegram Bot API client
- **[CouchDB Swift](https://github.com/makoni/couchdb-swift)** `2.1.0+` - CouchDB client library
- **[Swift Configuration](https://github.com/apple/swift-configuration)** `0.1.0+` - Unified configuration reader for environment variables and files

### Development Dependencies
- **VaporTesting** - Testing utilities for Vapor applications

## Deployment Instructions

### Prerequisites
- Swift 6.0+
- macOS 15.0+ or Linux with Swift 6 toolchain
- CouchDB instance (local or remote)
- Telegram Bot Token (from [@BotFather](https://t.me/botfather))

### Swift Package Manager (Development)

1. **Clone the repository**:
   ```bash
   git clone https://github.com/makoni/ReleaseInformerBot.git
   cd ReleaseInformerBot
   ```

2. **Set environment variables** (override as needed):
   ```bash
   export TELEGRAM_API_KEY="YOUR_TELEGRAM_BOT_TOKEN"
   export COUCH_HOST="127.0.0.1"
   export COUCH_USER="admin"
   export COUCH_PASSWORD=""
   export COUCH_PORT=5984
   ```

3. **Build and run**:
   ```bash
   swift build
   swift run
   ```

4. **Run tests**:
   ```bash
   swift test
   ```

### Configuration

The bot now uses [Swift Configuration](https://github.com/apple/swift-configuration) to resolve settings from multiple sources. The lookup order is:
1. Environment variables (using uppercase keys such as `TELEGRAM_API_KEY` or `COUCH_HOST`)
2. Optional JSON configuration file
3. Hard-coded defaults

Provide a JSON file at `config/config.json` (or set `RELEASE_INFORMER_CONFIG_PATH` to an absolute path) to manage settings locally:

```json
{
   "telegram": {
      "apiKey": "YOUR_TELEGRAM_BOT_TOKEN"
   },
   "couch": {
      "protocol": "http",
      "host": "127.0.0.1",
      "port": 5984,
      "user": "admin",
      "password": "",
      "requestsTimeout": 30
   },
   "runtime": {
      "bootstrapServices": true
   }
}
```

Set `runtime.bootstrapServices` to `false` (default in `testing` environment) to skip bot initialization and external service connections while still registering routes.

### Production Configuration

For production deployments, ensure:
- Set `LOG_LEVEL=info` or `LOG_LEVEL=warning`
- Provide CouchDB credentials via configuration (environment variables or JSON file)
- Use proper secrets management for the Telegram bot token
- Set up monitoring and health checks on port 8080
- Ensure the `couchdb-swift_CouchDBClient.resources` bundle is deployed alongside the binary. When you build with SwiftPM (e.g., `swift build --swift-sdk x86_64-swift-linux-musl -c release`), copy both of these paths to the server directory where you host the executable:
   - `.build/x86_64-swift-linux-musl/release/ReleaseInformerBot`
   - `.build/x86_64-swift-linux-musl/release/couchdb-swift_CouchDBClient.resources`
   A minimal deployment directory on the server should look like:
   ```
   /home/user/ReleaseInformerBot
   ├── ReleaseInformerBot
   └── couchdb-swift_CouchDBClient.resources/
   ```

## CouchDB Setup

The bot will automatically create the required CouchDB database (`release_bot`) and design document with the necessary views on startup.

**Automatic Setup:**

- The `DBManager` includes a `setupIfNeed()` method that checks for the existence of the database and required views, and creates them if they do not exist. No manual setup is required for most users—just ensure your CouchDB instance is running and credentials are provided through configuration.

**Manual Setup (optional):**

If you prefer to create the database and design document manually, use the following JSON for the design document:

```json
{
   "_id": "_design/list",
   "language": "javascript",
   "views": {
       "by_bundle": {
           "map": "function(doc) {\n  emit(doc.bundle_id, doc);\n}"
       },
       "by_chat": {
           "map": "function(doc) {\n  for (var i=0; i<doc.chats.length; i++) {\n    emit(doc.chats[i], doc);\n  }\n}"
       }
   }
}
```

Create a database named `release_bot` and add this design document for optimal performance.
