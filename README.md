# Release Informer Bot

Simple Telegram bot that will inform you on when the new version of an app released in App Store.

Requirements:
- Node.js
- CouchDB

Try: https://telegram.me/ReleaseInformerBot

Install:

```bash
npm install pm2 -g
npm install
TOKEN='TOKEN' pm2 start index.js --watch
```

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
