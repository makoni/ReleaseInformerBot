"use strict";

// Config
const config = require('./config');

// Libs
const TelegramBot = require('node-telegram-bot-api');

// CouchDB object
const nodeCouchDB = require("node-couchdb");
const couch = new nodeCouchDB(config.couchDbHost, config.couchDbPort);

// Telegram Bot
let telegramBot = new TelegramBot(config.token, {polling: true});

// Release Bot
const ReleaseBot = require('./lib/release_bot');
let releaseBot = new ReleaseBot(telegramBot, couch);

// Watcher to check updates in iTunes
const ReleasesWatcher = require('./lib/release_watcher');
let releaseWatcher = new ReleasesWatcher(releaseBot, couch);
