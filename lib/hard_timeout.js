'use strict';

function hardTimeoutMs(penthouseTimeoutMs, bufferMs) {
  const timeout = parseInt(penthouseTimeoutMs || 30000, 10);
  const buffer = parseInt(
    bufferMs === undefined || bufferMs === null ? 10000 : bufferMs,
    10
  );
  return timeout + buffer;
}

// Race a hung Chromium/pagePromise against a hard ceiling so the Node process can exit.
// penthouse may reject its own timeout then block forever re-awaiting pagePromise.
function withHardTimeout(promise, timeoutMs) {
  return Promise.race([
    promise,
    new Promise(function(_, reject) {
      setTimeout(function() {
        reject(new Error(
          'Critical CSS generation hard-timed out after ' + timeoutMs +
          'ms (Chromium/page launch may be hung)'
        ));
      }, timeoutMs);
    })
  ]);
}

module.exports = {
  hardTimeoutMs: hardTimeoutMs,
  withHardTimeout: withHardTimeout
};
