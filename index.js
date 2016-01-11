"use strict";

// Require
var TelegramBot = require('node-telegram-bot-api');
var request = require('request');
var vow = require('vow');
var sleep = require('sleep');
var nodeCouchDB = require("node-couchdb");

// CouchDB object
var couch = new nodeCouchDB("localhost", 5984);
var couchDBName = 'release_bot';

// Watcher to check updates in iTunes
var releaseWatcherObject = new ReleasesWatcher();

// Telegram Bot
var token = process.env.TOKEN;
var bot = new TelegramBot(token, {polling: true});


////////////////////////////////////////////////////////////////////////////////////////////////////

// Help command
bot.onText(/\/help/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var helpText = 'Help: \n\n/help - help\n';
	helpText += '/search [appName] - search app by name. Example: /search GMail\n';
	helpText += '/add [bundle ID] - subscribe for notifications about new versions of app by Bundle ID (you can find it with /search). Example: /add com.google.Gmail\n';
	helpText += '/del [bundle ID] - unsubscribe from notifications about new versions by Bundle ID. Example: /del com.google.Gmail\n';
	helpText += '/list - list of subscribtions\n';
	bot.sendMessage(fromId, helpText);
});

// List command
bot.onText(/\/list/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	
	// getting all chat subscriptions
	searchInDbByChat(fromId)

		// Creating text message from results
		.then(
			function(results) {
				if (results.length > 0) {
					var searchResults = [];
					for (var i=0; i<results.length; i++) {
						var result = results[i].value;						

						var resultObject = new SearchResultObject();
						resultObject.title = result.title;
						resultObject.bundleId = result.bundle_id;
						resultObject.url = result.url;
						resultObject.version = result.version;

						searchResults.push(resultObject);
					}

					return createTextFromResults(searchResults);
				} else {
					bot.sendMessage(fromId, 'You have no subscribtions yet.');
				}
			},
			function(err) { bot.sendMessage(fromId, 'You have no subscribtions yet.'); }
		)

		// Sending message to user with subscriptions list
		.then(
			function(text) { if (text.length > 0) bot.sendMessage(fromId, text); }
		);
});

// Search command
bot.onText(/\/search (.+)/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var searchText = match[1];

	// Searching in iTunes by title
	searchInITunesByTitle(searchText)

		// handling results
		.then(
			function(result) { return parseSearchResults(result); },
			function(err) {bot.sendMessage(fromId, err); }
		)

		// creating text message from results
		.then(
			function(searchResults) { return createTextFromResults(searchResults); }
		)

		// sending message to chat
		.then(
			function(text) { bot.sendMessage(fromId, text); }
		); 
});

// Add command
bot.onText(/\/add (.+)/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var bundleToSearch = match[1];

	// searching in iTunes by Bundle ID
	searchInITunesByBundleId(bundleToSearch)

		// check if searched bundle is in results
		.then(
			function(results) { return findBundleInResults(results, bundleToSearch); },
			function(error) { bot.sendMessage(fromId, error); } 
		)

		// subscribing chat for updates
		.then(
			function(result) { 
				var resultObject = new SearchResultObject();
				resultObject.title = result.trackName;
				resultObject.bundleId = result.bundleId;
				resultObject.url = result.trackViewUrl;
				resultObject.version = result.version;

				return subscribeForNewVersions(resultObject, fromId); 
			},
			function(err) { reject(err); } 
		)

		// sending result message to chat
		.then(
			function(result) { bot.sendMessage(fromId, bundleToSearch + ' added to your subscriptions. I will inform you when the new version will come out.');  },
			function(err) { bot.sendMessage(fromId, "Could not find app with such bundle in App Store"); } 
		);
});

// Del command
bot.onText(/\/del (.+)/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var bundleToSearch = match[1];

	// unsubscribing
	unsubscribeForNewVersions(bundleToSearch, fromId)	

		// sending result message to chat	
		.then(
			function(result) { bot.sendMessage(fromId, bundleToSearch + ' removed from your subscriptions.'); },
			function(err) { bot.sendMessage(fromId, 'Something is wrong =('); } 
		);
});


////////////////////////////////////////////////////////////////////////////////////////////////////

// Find bundle in iTunes Search Results
var findBundleInResults = function(results, bundleToSearch) {
	return new vow.Promise(function(resolve, reject, notify) {
		var found = false;		

		for (var i = 0; i<results.results.length; i++) {
			var resultObject = results.results[i];

			if (resultObject.bundleId === bundleToSearch) {				
				resolve(resultObject);
				found = true;
				return;
			}
		}

		if (found === false) {			
			reject('App with bundle ' + bundleToSearch + ' not found.');
		}		
	});	
}

// Search in iTunes by Title using API
var searchInITunesByTitle = function(searchText) {
	return new vow.Promise(function(resolve, reject, notify) {
		var searchString = 'https://itunes.apple.com/search?term=' + encodeURI(searchText) + '&entity=software';

		request({url:searchString}, function (error, response, body) {
			if (error || response.statusCode > 400) {
				reject(error);
			} else {				
				var result = JSON.parse(body);
				resolve(result);
		  	}
		})
	});	
};

// Search in iTunes by Bundle ID using API
var searchInITunesByBundleId = function(searchText, appObject) {
	return new vow.Promise(function(resolve, reject, notify) {
		var searchString = 'https://itunes.apple.com/lookup?bundleId=' + encodeURI(searchText);	

		request({url:searchString}, function (error, response, body) {
			if (error || response.statusCode >= 400) {
				reject(error);
			} else {				
				var result = JSON.parse(body);
				if (appObject === undefined) {
					resolve(result);
				} else {
					resolve([result, appObject]);
				}
		  	}
		})
	});	
};

// Create simple objects with only required fiels from iTunes search results
var parseSearchResults = function(result) {
	return new vow.Promise(function(resolve, reject, notify) {
		var results = [];

		for (var i = 0; i<result.results.length; i++) {
			var found = result.results[i];

			var resultObject = new SearchResultObject();
			resultObject.title = found.trackName;
			resultObject.bundleId = found.bundleId;
			resultObject.url = found.trackViewUrl;
			resultObject.version = found.version;
			
			results.push(resultObject);			
		}

		resolve(results);
	});
};

// Create text message from iTunes results
var createTextFromResults = function(results) {
	return new vow.Promise(function(resolve, reject, notify) {
		var text = 'Results:\n\n'

		var max = (results.length > 10) ? 10 : results.length;
		for (var i = 0; i<max; i++) {
			var resultObject = results[i];
			text += resultObject.title + '\n';
			text += 'Version: ' + resultObject.version + '\n';
			text += resultObject.url + '\n';
			text += 'Bundle ID: ' + resultObject.bundleId + '\n\n';
		}

		if (results.length == 0) {
			text += 'Nothing found =(';
		}

		if (results.length > 10) {
			text += 'And ' + (results.length - 10) + ' more.';
		}

		resolve(text);
	});
};

// Find Apps in local DB by Chat ID (chat subscriptions)
var searchInDbByChat = function(chat) {
	return new vow.Promise(function(resolve, reject, notify) {

		var viewUrl = "_design/list/_view/by_chat";
		var queryOptions = {
			key: chat,		
		};
		var found = false;

		couch.get(couchDBName, viewUrl, queryOptions, function (err, resData) {
			if (err) {
				reject(err);
				return;
			} else if (resData.data.rows.length == 0) {
				reject('Nothing found');
				return;
			} else {		
				resolve(resData.data.rows);				
			}
		});
	});
};

// Find App in local DB by Bundle ID
var searchInDbByBundleId = function(bundle) {
	return new vow.Promise(function(resolve, reject, notify) {

		var viewUrl = "_design/list/_view/by_bundle";
		var queryOptions = {
			key: bundle,		
		};
		var found = false;

		couch.get(couchDBName, viewUrl, queryOptions, function (err, resData) {
			if (err) {
				reject('Nothing found');
				return;
			} else if (resData.data.rows.length == 0) {
				reject('Nothing found');
				return;
			} else {				
				resolve(resData.data.rows[0]);			
			}
		});
	});
};

// Subscribe chat for app updates
var subscribeForNewVersions = function(searchResult, chat) {	
	return new vow.Promise(function(resolve, reject, notify) {		

		// searching in local DB for app
		searchInDbByBundleId(searchResult.bundleId)

			.then(

				// adding chat to subscribers
				function(documentObject) {  
					if (documentObject.value.chats.indexOf(chat) === -1) {
						documentObject.value.chats.push(chat);

						couch.update(couchDBName, documentObject.value, function (err, resData) {
							if (err) { 
								reject(err);
							}
							else resolve(resData);
						});
					} else {
						resolve(documentObject);
					}					
				},

				// creating new document for the App because it's new app
				function(error) { 

					couch.uniqid(1, function (err, ids) {
						couch.insert(couchDBName, {
							_id: ids[0],
							bundle_id: searchResult.bundleId,
							url: searchResult.url,
							title: searchResult.title,
							version: searchResult.version,
							chats: [chat]
						}, function (err, resData) {
							if (err) {
								reject(err);
							} 
						 	else resolve(resData);
						});
					});
				}
			);
	});
};

// Unsubscribe chat from App updates
var unsubscribeForNewVersions = function(bundle, chat) {
	return new vow.Promise(function(resolve, reject, notify) {

		searchInDbByBundleId(bundle)
			.then(
				function(documentObject) {  
					if (documentObject.value.chats.indexOf(chat) != -1) {
						documentObject.value.chats.splice(documentObject.value.chats.indexOf(chat),1);

						couch.update(couchDBName, documentObject.value, function (err, resData) {
							if (err) { 
								reject(err);
							}
							else resolve(resData);
						});
					} else {
						resolve(documentObject);
					}					
				},
				function(error) { 
					resolve({});
				}
			);
	});
}

// Search Result Model constuctor
function SearchResultObject() {
	this.title = '';
	this.bundleId = '';
	this.url = '';
	this.version = '';
};



////////////////////////////////////////////////////////////////////////////////////////////////////

// Release Watcher Object constructor
function ReleasesWatcher() {
	this.start = function() {

	};

	// inform chats about new versions
	this.informAboutNewRelease = function(appObject, searchResult) {
		return new vow.Promise(function(resolve, reject, notify) {			
			if (appObject === null && searchResult === null) {
				reject();
				return;
			}

			var newVersion = searchResult.version;

			var text = "New version released! Version " + newVersion + "\n\n";

			text += appObject.title + '\n';
			text += 'Version: ' + newVersion + '\n';
			text += appObject.url + '\n';
			text += 'Bundle ID: ' + appObject.bundle_id + '\n\n';

			for (var i = 0; i<appObject.chats.length; i++) {
				sleep.sleep(1);
				var chatId = appObject.chats[i];
				bot.sendMessage(chatId, text);
			}
			
			resolve([appObject, searchResult]);
		});		
	};

	// check if app version in local DB is equal to app version in iTunes
	this.checkVersions = function(appObject, iTunesResult) {
		return new vow.Promise(function(resolve, reject, notify) {
			if (iTunesResult.version != undefined && iTunesResult.version != appObject.version) {				
				resolve([appObject, iTunesResult]);
			} else {
				reject();
			}
		});
	};

	// get all apps from local database
	this.getAllBundles = function() {
		return new vow.Promise(function(resolve, reject, notify) {
			var viewUrl = "_design/list/_view/by_bundle";
			var queryOptions = {};
			var found = false;

			couch.get(couchDBName, viewUrl, queryOptions, function (err, resData) {				
				if (err) {
					reject(err);
				} else {				
					resolve(resData.data.rows);				
				}
			});
		});
	}; 
}

////////////////////////////////////////////////////////////////////////////////////////////////////

// function for interval
function checkForUpdates() {

	// get all apps from local DB
	releaseWatcherObject.getAllBundles()
		.then(
			function(allBundlesFromLocalDBArray) { 			

				for (var i = 0; i<allBundlesFromLocalDBArray.length; i++) {
					sleep.sleep(1);				

					// getting App from iTunes by Bundle ID
					searchInITunesByBundleId(allBundlesFromLocalDBArray[i].value.bundle_id, allBundlesFromLocalDBArray[i].value)

						// check if App version is different
						.then(
							function(results) {
								var localAppObject = results[1];
								var foundInITunes = results[0].results[0];
								return releaseWatcherObject.checkVersions(localAppObject, foundInITunes); 
							},
							function(error) { console.log("Error: " + error);  } 
						)

						// inform chats about new version release
						.then(
							function(results) { return releaseWatcherObject.informAboutNewRelease(results[0], results[1]); },
							function() { return releaseWatcherObject.informAboutNewRelease(null, null);  }
						)

						// update App version in local DB
						.then(
							function(result) {
								var localAppObject = result[0];
								var iTunesSearchResult = result[1];

								// saving new app version in local database
								localAppObject.version = iTunesSearchResult.version;

								couch.update(couchDBName, localAppObject, function (err, resData) { 
									if (err) { 
										console.log(err);
									}
								});
							},
							function() {
								// versions are equal
							}
						);
				}
			},
			function(err) { console.log('Could not fetch data from CouchDB'); } // onRejected reaction
		);	
}

////////////////////////////////////////////////////////////////////////////////////////////////////

// starting Watcher
setInterval(checkForUpdates, 1000 * 60 * 30);
checkForUpdates();










