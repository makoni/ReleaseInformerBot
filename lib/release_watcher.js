'use strict';

// Config
const config = require('../config');

// Utils
const utils = require('./utils');

// Libs
const sleep = require('sleep');


// ReleaseWatcher class
class ReleaseWatcher {

    constructor(releaseBot, couch) {
        this.releaseBot = releaseBot;
        this.couch = couch;

        // this.checkForUpdates();
        setTimeout(this.checkForUpdates.bind(this), 1000*5);
        setInterval(this.checkForUpdates.bind(this), config.requestTimeout);
    }

    // method for interval
    checkForUpdates() {
        utils.p("check for updates");
        let self = this;

        self.getAllBundles()
            .then(
                allBundlesFromLocalDBArray => {
                    utils.p("check for updates");
                    utils.p('bundles count: ' + allBundlesFromLocalDBArray.length);

                    for (let i = 0, k = allBundlesFromLocalDBArray.length; i < k; i++) {

                         setTimeout(() => {
                            let bundle_id = allBundlesFromLocalDBArray[i].value.bundle_id;
                        // getting App from iTunes by Bundle ID
                        utils.p( i + '. searching ' + bundle_id + ' in iTunes');
                        self.releaseBot.searchInITunesByBundleId(bundle_id, allBundlesFromLocalDBArray[i].value)
                            // check if App version is different
                            .then(
                                results => {
                                    let localAppObject = results[1];
                                    let foundInITunes = results[0].results[0];
                                    return self.checkVersions(localAppObject, foundInITunes);
                                },
                                error => { console.log("Error!!: " + error); }
                            )

                            // inform chats about new version release
                            .then(
                                results => { return self.informAboutNewRelease(results[0], results[1]); },
                                () => { return self.informAboutNewRelease(null, null); }
                            )

                            // update App version in local DB
                            .then(
                                result => {
                                    let localAppObject = result[0];
                                    let iTunesSearchResult = result[1];

                                    if (Array.isArray(localAppObject.version) === false) {
                                        let array = [localAppObject.version];
                                        localAppObject.version = array;
                                    }

                                    // saving new app version in local database
                                    // localAppObject.version = iTunesSearchResult.version;

                                    localAppObject.version.push(iTunesSearchResult.version);
                                    self.couch.update(config.couchDbDatabase, localAppObject).then(
                                        () => {},
                                        err => { console.log(err); }
                                    );
                                },
                                () => { /* versions are equal */ }
                            );

                         }, 1000*i);
                    }
                },
                // onRejected reaction
                err => { utils.p('Could not fetch data from CouchDB: ' + err); }
            );
    }

    // get all apps from local database
    getAllBundles() {
        let self = this;
        return new Promise((resolve, reject) => {
            const viewUrl = "_design/list/_view/by_bundle";
            const queryOptions = {};

            self.couch.get(config.couchDbDatabase, viewUrl, queryOptions).then(
                resData => { resolve(resData.data.rows); },
                err => { reject(err); }
            );
        });
    }

    // check if app version in local DB is equal to app version in iTunes
    checkVersions(appObject, iTunesResult) {
		return new Promise((resolve, reject) => {
			if (iTunesResult.version !== undefined) {
                if ( Array.isArray(appObject.version) === true ) {
                    if (appObject.version.indexOf(iTunesResult.version) !== -1) {
                        reject();
                    } else {
                        resolve([appObject, iTunesResult]);
                    }
                } else if (iTunesResult.version !== appObject.version) {
				    resolve([appObject, iTunesResult]);
                } else {
                    reject();
                }
			} else {
				reject();
			}
		});
	}

    // inform chats about new versions
    informAboutNewRelease(appObject, searchResult) {
        let self = this;

        return new Promise((resolve, reject) => {
            if (appObject === null && searchResult === null) {
                reject();
                return;
            }

            const newVersion = searchResult.version;

            utils.p('App ' + appObject.bundle_id + ' updated to version ' + newVersion);

            let text = "New version released! Version " + newVersion + "\n\n";
            text += appObject.title + '\n';
            text += 'Version: ' + newVersion + '\n';
            text += appObject.url + '\n';
            text += 'Bundle ID: ' + appObject.bundle_id + '\n\n';

            if (searchResult.releaseNotes !== undefined) {
                text += "What's new: ";
                text += '\n' + searchResult.releaseNotes + '\n';
            }

            for (let i = 0; i<appObject.chats.length; i++) {
                sleep.sleep(1);
                const chatId = appObject.chats[i];
                utils.p('Sending to chat: ' + chatId);
                self.releaseBot.bot.sendMessage(chatId, text)
                    .then(
                        (sended) => {},
                        (error) => {
                            utils.p("error for chat: " + chatId + ' - Bundle ID: ' + appObject.bundle_id);
                        });
            }

            resolve([appObject, searchResult]);
        });
    }
}

module.exports = ReleaseWatcher;
