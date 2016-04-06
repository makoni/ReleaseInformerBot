'use strict';

class SearchResult {
    constructor(data) {
        this.title = data.title || data.trackName || '';
    	this.bundleId = data.bundleId || data.bundle_id || '';
    	this.url = data.url || data.trackViewUrl || '';
    	this.version = data.version || '';
    }
}

module.exports = SearchResult;
