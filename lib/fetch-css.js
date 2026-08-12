const penthouse = require('penthouse');
const puppeteer = require('puppeteer');
const fs = require('fs');
const {hardTimeoutMs, withHardTimeout} = require('./hard_timeout');

const penthouseOptions = JSON.parse(process.argv[2]);

const STDOUT_FD = 1;
const STDERR_FD = 2;

// YAML/JSON cannot pass a JS getBrowser function through Ruby Open3.
// Chromium launch args are configured in Ruby (CssFetcher::CHROMIUM_LAUNCH_ARGS) and
// passed as puppeteer.args; wrap them into getBrowser here.
const puppeteerOpts = Object.assign({}, penthouseOptions.puppeteer);
const launchArgs = puppeteerOpts.args || [];
delete puppeteerOpts.args;

penthouseOptions.puppeteer = Object.assign({}, puppeteerOpts, {
  getBrowser: function getBrowser() {
    return puppeteer.launch({
      args: launchArgs,
      ignoreHTTPSErrors: true,
      defaultViewport: {
        width: parseInt(penthouseOptions.width || 1300, 10),
        height: parseInt(penthouseOptions.height || 900, 10)
      }
    });
  }
});

const timeoutMs = hardTimeoutMs(
  penthouseOptions.timeout,
  penthouseOptions.node_hard_timeout_buffer_ms
);

function exitWithError(err) {
  const message = err && err.stack ? err.stack : String(err);
  try {
    fs.writeSync(STDERR_FD, message + '\n');
  } catch (_) {
    // ignore secondary write failures during forced exit
  }
  process.exit(1);
}

withHardTimeout(penthouse(penthouseOptions), timeoutMs).then(function (criticalCss) {
  fs.writeSync(STDOUT_FD, criticalCss);
  process.exit(0);
}).catch(exitWithError);
