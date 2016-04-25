'use strict';

const ReleaseBot = require('../lib/release_bot');
let releaseBot = new ReleaseBot();

////////////////////////////////////////////////////////////////////////////////

describe("ReleaseBot Class Tests --> ", function() {

    let results = new Array();

    describe("Search -> ", function() {
        it("CompareShots", function(done) {
            // searching in iTunes by Bundle ID
            releaseBot.searchInITunesByBundleId('com.arm1.ru.compareshots')
                .then( // check if searched bundle is in results
                    resultForTest => {
                        expect(resultForTest.title).not.toBeUndefined();
                        expect(resultForTest.bundleId).not.toBeUndefined();
                        expect(resultForTest.url).not.toBeUndefined();
                        expect(resultForTest.version).not.toBeUndefined();

                        results.push(resultForTest);
                        done();
                    }
                );
        });
    });

});
