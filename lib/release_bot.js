'use strict';

// Config
const config = require('../config');

// Utils
const utils = require('./utils');

// Libs
const request = require('request');

// Models
const SearchResult = require('../models/search_result');


// ReleaseBot class
class ReleaseBot {
    constructor(telegramBot, couch) {
        let self = this;

        if (couch !== undefined) {
            self.couch = couch;
        }

        if (telegramBot !== undefined) {
            self.bot = telegramBot;
            let bot = self.bot;

            // Help command
            bot.onText(/\/help/, (msg) => {

                let messageForTrack = msg;
                messageForTrack.from.id = messageForTrack.from.id || messageForTrack.chat.id;

                utils.p('hello command');
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
            bot.onText(/\/list/, async (msg) => {
                utils.p('list command');

                let messageForTrack = msg;
                messageForTrack.from.id = messageForTrack.from.id || messageForTrack.chat.id;

            	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
            	
				// getting all chat subscriptions
				try {
					const text = await self.searchInDbByChat(fromId);
					bot.sendMessage(fromId, text);
				} catch (error) {
					console.log(error); 
					bot.sendMessage(fromId, 'You have no subscribtions yet.');
				}

            });

            // Search command
            bot.onText(/\/search (.+)/, async (msg, match) => {
                utils.p('search command');

                let messageForTrack = msg;
                messageForTrack.from.id = messageForTrack.from.id || messageForTrack.chat.id;

            	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
            	const searchText = match[1];

            	// Searching in iTunes by title
				try {
					const text = await self.searchInITunesByTitle(searchText);
					bot.sendMessage(fromId, text);
				} catch (error) {
					bot.sendMessage(fromId, error);
				}
            });

            // Add command
            bot.onText(/\/add (.+)/, async (msg, match) => {
                utils.p('add command');

                let messageForTrack = msg;
                messageForTrack.from.id = messageForTrack.from.id || messageForTrack.chat.id;

            	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
            	const bundleToSearch = match[1];

            	// searching in iTunes by Bundle ID
				try {
					const appObject = await self.searchInITunesByBundleId(bundleToSearch);
					await self.subscribeForNewVersions(appObject, fromId);
					bot.sendMessage(fromId, bundleToSearch + ' added to your subscriptions. I will inform you when the new version will come out.');
				} catch (error) {
					console.log(error);
					bot.sendMessage(fromId, "Could not find app with such bundle in App Store");
				}
            });

            // Del command
            bot.onText(/\/del (.+)/, async (msg, match) => {
                utils.p('del command');

                let messageForTrack = msg;
                messageForTrack.from.id = messageForTrack.from.id || messageForTrack.chat.id;

            	const fromId = (msg.chat) ? msg.chat.id : msg.from.id;
            	const bundleToSearch = match[1].trim();

            	// unsubscribing
				try {
					await self.unsubscribeForNewVersions(bundleToSearch, fromId);
					bot.sendMessage(fromId, bundleToSearch + ' removed from your subscriptions.');
				} catch (error) {
					console.log(error);
					bot.sendMessage(fromId, 'Something is wrong =(');
				}
            });
        }
	}

    // Find bundle in iTunes Search Results
    findBundleInResults(results, bundleToSearch) {
    	return new Promise((resolve, reject) => {
    		for (let i = 0, k = results.results.length; i<k; i++) {
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

    	return new Promise( async (resolve, reject) => {
			let documentObject;
			try {
				documentObject = await self.searchInDbByBundleId(bundle);
			} catch (error) {
				console.log(error); 
				resolve({});
				return;
			}

			if (documentObject.value.chats.indexOf(chat) !== -1) {
				documentObject.value.chats.splice(documentObject.value.chats.indexOf(chat),1);
				
				try {
					const resData = await self.couch.update(config.couchDbDatabase, documentObject.value);
					resolve(resData);
				} catch (error) {
					reject(error);
				}

				return;
			} 
				
			resolve(documentObject);
    	});
    }

    // Find Apps in local DB by Chat ID (chat subscriptions)
    searchInDbByChat(chat) {
        let self = this;

    	return new Promise( async (resolve, reject) => {
    		const viewUrl = "_design/list/_view/by_chat";
    		const queryOptions = {
    			key: chat
    		};
			let resData;

			try {
				resData = await self.couch.get(config.couchDbDatabase, viewUrl, queryOptions);
			} catch (error) {
				console.log(error);
				reject(error);
				return;
			}

			if (resData.data.rows.length === 0) {
				reject('Nothing found');
				return;
			} 
			
			let searchResults = [];
			let results = resData.data.rows;
			for (let i=0; i<results.length; i++) {
				let resultObject = new SearchResult(results[i].value);
				searchResults.push(resultObject);
			}
			let text = self.createTextFromResults(searchResults);
			resolve(text);
    	});
    }

    // Create text message from iTunes results
    createTextFromResults(results) {
		let text = 'Results:\n\n';

		const max = (results.length > 10) ? 10 : results.length;
		for (let i = 0; i<max; i++) {
			let resultObject = results[i];
			text += resultObject.title + '\n';
			const version = (Array.isArray(resultObject.version) === true) ? resultObject.version[resultObject.version.length - 1] : resultObject.version;
			text += 'Version: ' + version + '\n';
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
    }

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
    }

    // Search in iTunes by Bundle ID using API
    searchInITunesByBundleId(bundleToSearch, appObject) {
        let self = this;

    	return new Promise((resolve, reject) => {
    		const searchString = 'https://itunes.apple.com/lookup?bundleId=' + encodeURI(bundleToSearch);
    		request({ url : searchString }, async (error, response, body) => {
    			if (error || response.statusCode >= 400) { reject(error); return; }

                let searchResults = JSON.parse(body);

				if (appObject === undefined) {
					try {
						const result = await self.findBundleInResults(searchResults, bundleToSearch);
						resolve( new SearchResult(result) );
					} catch (searchError) {
						reject(searchError);
					}
				} else {
					resolve([searchResults, appObject]);
				}
    		});
    	});
    }

    // Search in iTunes by Title using API
    searchInITunesByTitle(searchText) {
    	return new Promise((resolve, reject) => {
    		const searchString = 'https://itunes.apple.com/search?term=' + encodeURI(searchText.trim()) + '&entity=software';

    		request({ url : searchString }, async (error, response, body) => {
    			if (error || response.statusCode > 400) {
    				reject(error);
                    return;
    			}

				const searchResults = await this.parseSearchResults( JSON.parse(body) );
				resolve( this.createTextFromResults(searchResults) );
    		});
    	});
    }

    // Subscribe chat for app updates
    subscribeForNewVersions(searchResult, chat) {
        let self = this;

    	return new Promise( async (resolve, reject) => {

			try {
				// searching in local DB for app
				let documentObject = await self.searchInDbByBundleId(searchResult.bundleId);
				
				// adding chat to subscribers
				if (documentObject.value.chats.indexOf(chat) === -1) {
					documentObject.value.chats.push(chat);
					self.couch.update(config.couchDbDatabase, documentObject.value).then(
						resData => { resolve(resData); },
						err => { reject(err); }
					);
				} else {
					resolve(documentObject);
				}
			} catch (error) {
				
				self.couch.uniqid().then(
					ids => {
						self.couch.insert(config.couchDbDatabase, {
							_id: ids[0],
							bundle_id: searchResult.bundleId,
							url: searchResult.url,
							title: searchResult.title,
							version: [searchResult.version],
							chats: [chat]
						}).then(
							resData => { resolve(resData); },
							insertError => { reject(insertError); }
						);
					}, err => {
						reject(err);
					});

			}
			
    	});
    }

    // Find App in local DB by Bundle ID
    searchInDbByBundleId(bundle) {
        let self = this;
    	return new Promise( async (resolve, reject) => {
    		const viewUrl = "_design/list/_view/by_bundle";
    		const queryOptions = { key: bundle };

			try {
				const resData = await self.couch.get(config.couchDbDatabase, viewUrl, queryOptions);
				if (resData.data.rows.length === 0) { reject('Nothing found'); return; }
				resolve(resData.data.rows[0]);
			} catch (error) {
				reject('Nothing found');
			}
    	});
    }

}

module.exports = ReleaseBot;
