"use strict";

var TelegramBot = require('node-telegram-bot-api');
var request = require('request');
var vow = require('vow');

var nodeCouchDB = require("node-couchdb");
var couch = new nodeCouchDB("localhost", 5984);
var couchDBName = 'release_bot';
 
var token =  process.env.TOKEN;
// Setup polling way 
var bot = new TelegramBot(token, {polling: true});

bot.onText(/\/help/, function (msg, match) {
	console.dir(msg);
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var helpText = 'Help: \n\n/help - help\n';
	helpText += '/search [appName] - search app by name. Example: /search GMail\n';
	helpText += '/add [bundle ID] - subscribe for notifications about new versions of app by Bundle ID (you can find it with /search). Example: /add com.google.Gmail\n';
	helpText += '/del [bundle ID] - unsubscribe from notifications about new versions by Bundle ID. Example: /del com.google.Gmail\n';
	helpText += '/list - list of subscribtions\n';
	bot.sendMessage(fromId, helpText);
});

bot.onText(/\/list/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	
	searchInDbByChat(fromId)
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

					console.log(results);

					return createTextFromResults(searchResults);
				} else {
					bot.sendMessage(fromId, 'You have no subscribtions yet.');
				}
			},
			function(err) {bot.sendMessage(fromId, err); }
		)
		.then(
			function(text) { bot.sendMessage(fromId, text); }
		);
});

bot.onText(/\/search (.+)/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var searchText = match[1];

	searchInITunesByTitle(searchText)
		.then(
			// обрабатываем результаты
			function(result) { return parseSearchResults(result); },
			function(err) {bot.sendMessage(fromId, err); } // onRejected reaction
		)
		.then(
			function(searchResults) { return createTextFromResults(searchResults); }
		)
		.then(
			function(text) { bot.sendMessage(fromId, text); }
		); 
});

bot.onText(/\/add (.+)/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var bundleToSearch = match[1];

	searchInITunesByBundleId(bundleToSearch)
		.then(
			// обрабатываем результаты
			function(results) {  return findBundleInResults(results, bundleToSearch); },
			function(error) { console.log(error);  } 
		)
		.then(
			function(result) { 
				var resultObject = new SearchResultObject();
				resultObject.title = result.trackName;
				resultObject.bundleId = result.bundleId;
				resultObject.url = result.trackViewUrl;
				resultObject.version = result.version;

				return subscribeForNewVersions(resultObject, fromId); 
			},
			function(err) { console.log(err); } 
		)
		.then(
			function(result) { bot.sendMessage(fromId, bundleToSearch + ' added to your subscriptions. I will inform you when the new version will come out.');  },
			function(err) { bot.sendMessage(fromId, 'Adding failed =('); } 
		);
});

bot.onText(/\/del (.+)/, function (msg, match) {
	var fromId = (msg.chat) ? msg.chat.id : msg.from.id;
	var bundleToSearch = match[1];

	searchInITunesByBundleId(bundleToSearch)
		.then(
			// обрабатываем результаты
			function(results) {  return findBundleInResults(results, bundleToSearch); },
			function(error) { console.log(error);  } 
		)
		.then(
			function(result) { return unsubscribeForNewVersions(result.bundleId, fromId); },
			function(err) { console.log(err); } 
		)
		.then(
			function(result) { bot.sendMessage(fromId, bundleToSearch + ' removed from your subscriptions.'); },
			function(err) { bot.sendMessage(fromId, 'Something is wrong =('); } 
		);
});
 
// Any kind of message 
bot.on('message', function (msg) {
  // var chatId = msg.chat.id;
  // // photo can be: a file path, a stream or a Telegram file_id 
  // var photo = 'cats.png';
  // bot.sendPhoto(chatId, photo, {caption: 'Lovely kittens'});
});


////////////////////////////////////////////////////////////////////////////////////////////////////


var findBundleInResults = function(results, bundleToSearch) {
	return new vow.Promise(function(resolve, reject, notify) {
		var found = false;		

		for (var i = 0; i<results.results.length; i++) {
			var resultObject = results.results[i];

			if (resultObject.bundleId === bundleToSearch) {				
				resolve(resultObject);
				found = true;
				break;
			}
		}

		if (found === false) {			
			reject('App with bundle ' + bundleToSearch + ' not found.');
		}		
	});	
}

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

var searchInITunesByBundleId = function(searchText) {
	return new vow.Promise(function(resolve, reject, notify) {
		var searchString = 'https://itunes.apple.com/lookup?bundleId=' + encodeURI(searchText);			

		request({url:searchString}, function (error, response, body) {
			if (error || response.statusCode >= 400) {
				reject(error);
			} else {				
				var result = JSON.parse(body);
				resolve(result);
		  	}
		})
	});	
};

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

var createTextFromResults = function(results) {
	return new vow.Promise(function(resolve, reject, notify) {
		var text = 'Results:\n\n'

		var max = (results.length > 4) ? 4 : results.length;
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

		if (results.length > 4) {
			text += 'And ' + (results.length - 4) + ' more.';
		}

		resolve(text);
	});
};

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
			} else if (resData.data.rows.length == 0) {
				reject('Not found');
			} else {		
				resolve(resData.data.rows);				
			}
		});
	});
};

var searchInDbByBundleId = function(bundle) {
	return new vow.Promise(function(resolve, reject, notify) {

		var viewUrl = "_design/list/_view/by_bundle";
		var queryOptions = {
			key: bundle,		
		};
		var found = false;

		couch.get(couchDBName, viewUrl, queryOptions, function (err, resData) {
			if (err) {
				reject(err);
			} else if (resData.data.rows.length == 0) {
				reject('Not found');
			} else {				
				resolve(resData.data.rows[0]);				
			}
		});
	});
};

var subscribeForNewVersions = function(searchResult, chat) {	
	return new vow.Promise(function(resolve, reject, notify) {

		console.log(searchResult);

		searchInDbByBundleId(searchResult.bundleId)
			.then(
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

function SearchResultObject() {
	this.title = '';
	this.bundleId = '';
	this.url = '';
	this.version = '';
};

////////////////////////////////////////////////////////////////////////////////////////////////////

// var bundleToSearch = 'com.arm1.ru.imetrik';










