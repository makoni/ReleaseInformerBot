'use strict';

let colors = require('colors');
colors.enabled = true;

exports.p = function logger(somethingForPrint) {
  somethingForPrint = somethingForPrint || '';
  const originalPrepareStackTrace = Error.prepareStackTrace;

  Error.prepareStackTrace = (error, stack) => { return stack; };

  let e = new Error();
  Error.captureStackTrace(e, logger);

  const stack = e.stack;
  const filename = stack[0].getFileName().split('/').reverse()[0];
  const trace = filename + ':' + stack[0].getLineNumber() + " " + colors.bold.black('%s') + "\n";

  Error.prepareStackTrace = originalPrepareStackTrace;

  console.log(trace, somethingForPrint);
};
