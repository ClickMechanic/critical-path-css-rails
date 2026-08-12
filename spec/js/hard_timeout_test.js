'use strict';

const assert = require('assert');
const { hardTimeoutMs, withHardTimeout } = require('../../lib/hard_timeout');

async function run() {
  assert.strictEqual(hardTimeoutMs(1000, 150), 1150);
  assert.strictEqual(hardTimeoutMs(1000), 11000);
  assert.strictEqual(hardTimeoutMs(undefined), 40000);

  const started = Date.now();
  let rejected = false;
  try {
    await withHardTimeout(new Promise(function() { /* never resolves */ }), 150);
  } catch (err) {
    rejected = true;
    assert.ok(
      /hard-timed out after 150ms \(Chromium\/page launch may be hung\)/.test(err.message),
      'unexpected message: ' + err.message
    );
  }
  assert.ok(rejected, 'hung promise should reject via hard timeout');
  assert.ok(Date.now() - started < 2000, 'hard timeout should fail fast, not hang');

  const value = await withHardTimeout(Promise.resolve('critical { color: red }'), 5000);
  assert.strictEqual(value, 'critical { color: red }');
}

run().then(function() {
  console.log('hard_timeout_test: ok');
}).catch(function(err) {
  console.error(err);
  process.exit(1);
});
