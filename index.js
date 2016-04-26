"use strict";

// Config
const config = require('./config');

// Utils
const utils = require('./lib/utils');

// Libs
const TelegramBot = require('node-telegram-bot-api');

// CouchDB object
const NodeCouchDb = require("node-couchdb");
const couch = new NodeCouchDb(config.couchDbHost, config.couchDbPort);

// Telegram Bot
let telegramBot = new TelegramBot(config.token, {polling: true});

// Release Bot
const ReleaseBot = require('./lib/release_bot');
let releaseBot = new ReleaseBot(telegramBot, couch);
utils.p('Bot started');

// Watcher to check updates in iTunes
const ReleasesWatcher = require('./lib/release_watcher');
let releaseWatcher = new ReleasesWatcher(releaseBot, couch);
releaseWatcher.checkForUpdates();
