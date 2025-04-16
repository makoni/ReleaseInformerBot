'use strict';

const SearchResult = require('../models/search_result');

////////////////////////////////////////////////////////////////////////////////

describe("Search Result Class Tests --> ", function() {

    describe("constructor -> ", function() {
        it("correct data", function(done) {
            const data = {
                title : 'test title',
                bundleId : 'test.bundle',
                url : "http://arm1.ru",
                version : '1.0'
            };

            let resultForTest = new SearchResult(data);

            expect(resultForTest.title).not.toBeUndefined();
            expect(resultForTest.title).toBe(data.title);

            expect(resultForTest.bundleId).not.toBeUndefined();
            expect(resultForTest.bundleId).toBe(data.bundleId);

            expect(resultForTest.url).not.toBeUndefined();
            expect(resultForTest.url).toBe(data.url);

            expect(resultForTest.version).not.toBeUndefined();
            expect(resultForTest.version).toBe(data.version);

            done();
        });
    });
});
