# Release Informer Bot for Telegram

A simple bot for Telegram that enables users to subscribe for notifications about new releases of an app in the App Store. It operates on the Vapor framework for server-side Swift development. 

## Getting Started

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

To execute tests, use the following command:
```bash
swift test
```

## View documents for CouchDB

Views for CouchDB:
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
