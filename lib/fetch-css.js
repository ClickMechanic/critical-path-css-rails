const penthouse = require('penthouse');
const puppeteer = require('puppeteer');
const fs = require('fs');

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

penthouse(penthouseOptions).then(function(criticalCss) {
  fs.writeSync(STDOUT_FD, criticalCss);
}).catch(function(err) {
  fs.writeSync(STDERR_FD, err);
  process.exit(1);
});
