'use strict';

// Config
const config = require('./config');
const sleep = require('sleep');

class ReleaseWatcher {

    constructor(releaseBot, couch) {
        this.releaseBot = releaseBot;
        this.couch = couch;

        this.checkForUpdates();
        setInterval(this.checkForUpdates.bind(this), config.requestTimeout);
    }

    // method for interval
    checkForUpdates() {
        let self = this;

        self.getAllBundles()
            .then(
                allBundlesFromLocalDBArray => {
                    for (let i = 0; i<allBundlesFromLocalDBArray.length; i++) {
                        sleep.sleep(1);

                        let bundle_id = allBundlesFromLocalDBArray[i].value.bundle_id;
                        // getting App from iTunes by Bundle ID
                        self.releaseBot.searchInITunesByBundleId(bundle_id, allBundlesFromLocalDBArray[i].value)
                            // check if App version is different
                            .then(
                                results => {
                                    let localAppObject = results[1];
                                    let foundInITunes = results[0].results[0];
                                    return self.checkVersions(localAppObject, foundInITunes);
                                },
                                error => { console.log("Error: " + error); }
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

                                    // saving new app version in local database
                                    localAppObject.version = iTunesSearchResult.version;

                                    self.couch.update(config.couchDbDatabase, localAppObject, (err, resData) => {
                                        if (err) { console.log(err); }
                                    });
                                },
                                () => { /* versions are equal */ }
                            );
                    }
                },
                // onRejected reaction
                err => { console.log('Could not fetch data from CouchDB: ' + err); }
            );
    }

    // get all apps from local database
    getAllBundles() {
        let self = this;
        return new Promise((resolve, reject) => {
            const viewUrl = "_design/list/_view/by_bundle";
            const queryOptions = {};

            self.couch.get(config.couchDbDatabase, viewUrl, queryOptions, (err, resData) => {
                if (err) { reject(err); } else { resolve(resData.data.rows); }
            });
        });
    };

    // check if app version in local DB is equal to app version in iTunes
    checkVersions(appObject, iTunesResult) {
		return new Promise((resolve, reject) => {
			if (iTunesResult.version !== undefined && iTunesResult.version !== appObject.version) {
				resolve([appObject, iTunesResult]);
			} else {
				reject();
			}
		});
	};

    // inform chats about new versions
    informAboutNewRelease(appObject, searchResult) {
        let self = this;

        return new Promise((resolve, reject) => {
            if (appObject === null && searchResult === null) {
                reject();
                return;
            }

            const newVersion = searchResult.version;

            let text = "New version released! Version " + newVersion + "\n\n";
            text += appObject.title + '\n';
            text += 'Version: ' + newVersion + '\n';
            text += appObject.url + '\n';
            text += 'Bundle ID: ' + appObject.bundle_id + '\n\n';

            if (searchResult.releaseNotes !== undefined) {
                text += "What's new: " + '\n';
                text += searchResult.releaseNotes + '\n';
            }

            for (let i = 0; i<appObject.chats.length; i++) {
                sleep.sleep(1);
                const chatId = appObject.chats[i];
                self.releaseBot.bot.sendMessage(chatId, text);
            }

            resolve([appObject, searchResult]);
        });
    };
}

module.exports = ReleaseWatcher;
