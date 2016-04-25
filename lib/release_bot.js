'use strict';

// Config
const config = require('../config');

// Utils
const utils = require('./utils');

// Libs
const request = require('request');

// Models
const SearchResult = require('../models/search_result');

class ReleaseBot {
    constructor(telegramBot, couch) {
        this.bot = telegramBot;
        this.couch = couch;
        let bot = this.bot;
        let self = this;

        // Help command
        this.bot.onText(/\/help/, (msg) => {
            utils.p('helo command');
        	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
        	let helpText = 'Help: \n\n/help - help.\n';
        	helpText += '/search [appName] - search app by name.\n';
        	helpText += '/add [bundle ID] - subscribe for notifications about new versions of app by Bundle ID (you can find it with /search).\n';
        	helpText += '/del [bundle ID] - unsubscribe from notifications about new versions by Bundle ID. Example: /del com.google.Gmail\n';
        	helpText += '/list - list of subscribtions\n\n';
            helpText += 'Examples:\n';
            helpText += '/search GMail\n';
            helpText += '/add com.google.Gmail\n';
            helpText += '/del com.google.Gmail\n';
            helpText += '/list\n';

        	bot.sendMessage(fromId, helpText);
        });

        // List command
        this.bot.onText(/\/list/, (msg) => {
            utils.p('list command');
        	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
        	// getting all chat subscriptions
        	self.searchInDbByChat(fromId)
        		.then(
        			text => { bot.sendMessage(fromId, text); },
        			err => { console.log(err); bot.sendMessage(fromId, 'You have no subscribtions yet.'); }
        		);
        });

        // Search command
        this.bot.onText(/\/search (.+)/, (msg, match) => {
            utils.p('search command');
        	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
        	const searchText = match[1];

        	// Searching in iTunes by title
        	self.searchInITunesByTitle(searchText)
        		.then( // handling results
        			text => { bot.sendMessage(fromId, text); },
        			err => { bot.sendMessage(fromId, err); }
        		);
        });

        // Add command
        this.bot.onText(/\/add (.+)/, (msg, match) => {
            utils.p('add command');
        	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
        	const bundleToSearch = match[1];

        	// searching in iTunes by Bundle ID
        	self.searchInITunesByBundleId(bundleToSearch)
        		.then( // check if searched bundle is in results
        			appObject => { return self.subscribeForNewVersions(appObject, fromId); },
        			error => { bot.sendMessage(fromId, error); }
        		)
        		.then( // sending result message to chat
        			result => { bot.sendMessage(fromId, bundleToSearch + ' added to your subscriptions. I will inform you when the new version will come out.'); },
        			err => { console.log(err); bot.sendMessage(fromId, "Could not find app with such bundle in App Store"); }
        		);
        });

        // Del command
        this.bot.onText(/\/del (.+)/, (msg, match) => {
            utils.p('del command');

        	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
        	const bundleToSearch = match[1].trim();

        	// unsubscribing
        	self.unsubscribeForNewVersions(bundleToSearch, fromId)
        		.then( // sending result message to chat
        			result => { bot.sendMessage(fromId, bundleToSearch + ' removed from your subscriptions.'); },
        			err => { console.log(err); bot.sendMessage(fromId, 'Something is wrong =('); }
        		);
        });
	}

    // Find bundle in iTunes Search Results
    findBundleInResults(results, bundleToSearch) {
    	return new Promise((resolve, reject) => {
    		for (let i = 0; i<results.results.length; i++) {
    			let resultObject = results.results[i];

    			if (resultObject.bundleId === bundleToSearch) {
    				resolve(resultObject);
    				return;
    			}
    		}

			reject('App with bundle ' + bundleToSearch + ' not found.');
    	});
    }

    // Unsubscribe chat from App updates
    unsubscribeForNewVersions(bundle, chat) {
        let self = this;

    	return new Promise((resolve, reject) => {
    		self.searchInDbByBundleId(bundle)
    			.then(
    				documentObject => {
    					if (documentObject.value.chats.indexOf(chat) !== -1) {
    						documentObject.value.chats.splice(documentObject.value.chats.indexOf(chat),1);

    						self.couch.update(config.couchDbDatabase, documentObject.value).then(
                                resData => { resolve(resData); },
                                err => { reject(err); }
                            );
    					} else {
    						resolve(documentObject);
    					}
    				},
    				error => { console.log(error); resolve({}); }
    			);
    	});
    };

    // Find Apps in local DB by Chat ID (chat subscriptions)
    searchInDbByChat(chat) {
        let self = this;

    	return new Promise((resolve, reject) => {
    		const viewUrl = "_design/list/_view/by_chat";
    		const queryOptions = {
    			key: chat,
    		};

            self.couch.get(config.couchDbDatabase, viewUrl, queryOptions).then(
                resData => {
                    if (resData.data.rows.length === 0) {
        				reject('Nothing found');
                    } else {
                        let searchResults = [];
                        let results = resData.data.rows;
                        for (let i=0; i<results.length; i++) {
                            let resultObject = new SearchResult(results[i].value);
                            searchResults.push(resultObject);
                        }
                        let text = self.createTextFromResults(searchResults);
        				resolve(text);
                    }
                }, err => {
                    reject(err);
                });
    	});
    };

    // Create text message from iTunes results
    createTextFromResults(results) {
		let text = 'Results:\n\n';

		const max = (results.length > 10) ? 10 : results.length;
		for (let i = 0; i<max; i++) {
			let resultObject = results[i];
			text += resultObject.title + '\n';
			text += 'Version: ' + resultObject.version + '\n';
			text += resultObject.url + '\n';
			text += 'Bundle ID: ' + resultObject.bundleId + '\n\n';
		}

		if (results.length === 0) {
			text += 'Nothing found =(';
		}

		if (results.length > 10) {
			text += 'And ' + (results.length - 10) + ' more.';
		}

		return text;
    };

    // Create simple objects with only required fiels from iTunes search results
    parseSearchResults(result) {
    	return new Promise((resolve) => {
    		let results = [];
    		for (let i = 0; i<result.results.length; i++) {
    			let resultObject = new SearchResult( result.results[i] );
    			results.push(resultObject);
    		}

    		resolve(results);
    	});
    };

    // Search in iTunes by Bundle ID using API
    searchInITunesByBundleId(bundleToSearch, appObject) {
        let self = this;

    	return new Promise((resolve, reject) => {
    		const searchString = 'https://itunes.apple.com/lookup?bundleId=' + encodeURI(bundleToSearch);
    		request({ url : searchString }, (error, response, body) => {
    			if (error || response.statusCode >= 400) { reject(error); return; }

                let searchResults = JSON.parse(body);

				if (appObject === undefined) {
                    self.findBundleInResults(searchResults, bundleToSearch)
                        .then(
                            result => { resolve( new SearchResult(result) ); },
                			err => { reject(err); }
                        );
				} else {
					resolve([searchResults, appObject]);
				}
    		});
    	});
    };

    // Search in iTunes by Title using API
    searchInITunesByTitle(searchText) {
    	return new Promise((resolve, reject) => {
    		const searchString = 'https://itunes.apple.com/search?term=' + encodeURI(searchText.trim()) + '&entity=software';

    		request({ url : searchString }, (error, response, body) => {
    			if (error || response.statusCode > 400) {
    				reject(error);
                    return;
    			}

                this.parseSearchResults( JSON.parse(body) )
                    .then(
                        searchResults => { resolve( this.createTextFromResults(searchResults) ); }
                    );
    		});
    	});
    };

    // Subscribe chat for app updates
    subscribeForNewVersions(searchResult, chat) {
        let self = this;

    	return new Promise((resolve, reject) => {
    		// searching in local DB for app
    		self.searchInDbByBundleId(searchResult.bundleId)
    			.then( // adding chat to subscribers
    				documentObject => {
    					if (documentObject.value.chats.indexOf(chat) === -1) {
    						documentObject.value.chats.push(chat);
    						self.couch.update(config.couchDbDatabase, documentObject.value).then(
                                resData => { resolve(resData); },
                                err => { reject(err); }
                            );
    					} else {
    						resolve(documentObject);
    					}
    				},

    				// creating new document for the App because it's new app
    				error => {
    					self.couch.uniqid().then(
                            ids => {
        						self.couch.insert(config.couchDbDatabase, {
        							_id: ids[0],
        							bundle_id: searchResult.bundleId,
        							url: searchResult.url,
        							title: searchResult.title,
        							version: searchResult.version,
        							chats: [chat]
        						}).then(
                                    resData => { resolve(resData); },
                                    insertError => { reject(insertError); }
        						);
    					    }, err => {
                                reject(err);
                            });
    				});
    	});
    };

    // Find App in local DB by Bundle ID
    searchInDbByBundleId(bundle) {
        let self = this;
    	return new Promise((resolve, reject) => {
    		const viewUrl = "_design/list/_view/by_bundle";
    		const queryOptions = { key: bundle };

    		self.couch.get(config.couchDbDatabase, viewUrl, queryOptions).then(
                resData => {
                    if (resData.data.rows.length === 0) { reject('Nothing found'); return; }
                    resolve(resData.data.rows[0]);
                }, err => {
                    reject('Nothing found');
                });
    	});
    };

}

module.exports = ReleaseBot;