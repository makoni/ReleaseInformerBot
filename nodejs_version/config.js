'use strict';

// CouchDB
exports.couchDbHost = 'localhost';
exports.couchDbPort = 5984;
exports.couchDbDatabase = 'release_bot';

exports.requestTimeout = 1000 * 60 * 30; // 20 seconds for long polling request timeout
exports.token = process.env.TOKEN || 'add-token-here';
exports.botanToken = process.env.BOTANTOKEN || 'add-token-here';
