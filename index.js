"use strict";

// Config
const config = require('./config');

// Libs
const TelegramBot = require('node-telegram-bot-api');
const request = require('request');
const sleep = require('sleep');

// CouchDB object
const nodeCouchDB = require("node-couchdb");
const couch = new nodeCouchDB(config.couchDbHost, config.couchDbPort);

// Telegram Bot
const token = process.env.TOKEN;
let telegramBot = new TelegramBot(config.token, {polling: true});

// Release Bot
const ReleaseBot = require('./release_bot');
let releaseBot = new ReleaseBot(telegramBot, couch);

// Watcher to check updates in iTunes
const ReleasesWatcher = require('./release_watcher');
let releaseWatcher = new ReleasesWatcher(releaseBot, couch);
