require 'json'
require 'open3'
require 'timeout'

module CriticalPathCss
  class CssFetcher
    GEM_ROOT = File.expand_path(File.join('..', '..'), File.dirname(__FILE__))

    # Extra seconds beyond penthouse timeout before Ruby kills a hung Node child.
    # Default keeps Ruby just outside the Node hard timeout (penthouse + 10s + 10s).
    # Overridable via penthouse_options['node_timeout_buffer_sec'].
    DEFAULT_NODE_TIMEOUT_BUFFER_SEC = 20

    # Extra ms beyond penthouse timeout for Node's hard-timeout race (hung pagePromise).
    # Overridable via penthouse_options['node_hard_timeout_buffer_ms'].
    DEFAULT_NODE_HARD_TIMEOUT_BUFFER_MS = 10_000

    # Heroku-24 (Ubuntu 24.04 / glibc 2.39) + Chromium bundled with puppeteer@2.1.1
    # (via penthouse@2.3.3): without --no-zygote/--single-process, Chromium dies in the
    # zygote with FATAL:sandbox::ThreadHelpers::IsSingleThreaded() and generation hangs.
    # --no-sandbox/--disable-setuid-sandbox are required with --no-zygote;
    # --disable-dev-shm-usage/--disable-gpu help on constrained dynos.
    # Overridable via penthouse_options['puppeteer']['args'] in critical_path_css.yml.
    CHROMIUM_LAUNCH_ARGS = [
      '--disable-setuid-sandbox',
      '--no-sandbox',
      '--ignore-certificate-errors',
      '--no-zygote',
      '--single-process',
      '--disable-dev-shm-usage',
      '--disable-gpu'
    ].freeze

    def initialize(config)
      @config = config
    end

    def fetch
      @config.routes.map { |route| [route, fetch_route(route)] }.to_h
    end

    def fetch_route(route)
      options = {
        'url' => @config.base_url + route,
        'css' => @config.path_for_route(route),
        'width' => 1300,
        'height' => 900,
        'timeout' => 30_000,
        # CSS selectors to always include, e.g.:
        'forceInclude' => [
          #  '.keepMeEvenIfNotSeenInDom',
          #  '^\.regexWorksToo'
        ],
        # set to true to throw on CSS errors (will run faster if no errors)
        'strict' => false,
        # characters; strip out inline base64 encoded resources larger than this
        'maxEmbeddedBase64Length' => 1000,
        # specify which user agent string when loading the page
        'userAgent' => 'Penthouse Critical Path CSS Generator',
        # ms; render wait timeout before CSS processing starts (default: 100)
        'renderWaitTime' => 100,
        # set to false to load (external) JS (default: true)
        'blockJSRequests' => true,
        'customPageHeaders' => {
          # use if getting compression errors like 'Data corrupted':
          'Accept-Encoding' => 'identity'
        }
      }.merge(@config.penthouse_options)

      # Deep-merge so a YAML `puppeteer:` hash does not wipe default Chromium args.
      options['puppeteer'] = { 'args' => CHROMIUM_LAUNCH_ARGS }.merge(options['puppeteer'] || {})

      # Ruby-only: do not forward to Node/penthouse.
      node_timeout_buffer_sec = options.delete('node_timeout_buffer_sec')
      node_timeout_buffer_sec = if node_timeout_buffer_sec.nil?
                                  DEFAULT_NODE_TIMEOUT_BUFFER_SEC
                                else
                                  node_timeout_buffer_sec.to_f
                                end

      options['node_hard_timeout_buffer_ms'] ||= DEFAULT_NODE_HARD_TIMEOUT_BUFFER_MS

      node_timeout_sec = (options['timeout'].to_f / 1000.0) + node_timeout_buffer_sec
      out, err, st = Dir.chdir(GEM_ROOT) do
        capture3_with_timeout(node_timeout_sec, 'node', 'lib/fetch-css.js', JSON.dump(options))
      end
      if !st.exitstatus.zero? || out.empty? && !err.empty?
        STDOUT.puts out
        STDERR.puts err
        STDERR.puts "Failed to get CSS for route #{route}\n" \
              "  with options=#{options.inspect}"
      end
      out
    end

    private

    def capture3_with_timeout(timeout_sec, *cmd)
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out = +''
        err = +''
        out_reader = Thread.new { out = stdout.read }
        err_reader = Thread.new { err = stderr.read }
        begin
          Timeout.timeout(timeout_sec) do
            status = wait_thr.value
            out_reader.join
            err_reader.join
            [out, err, status]
          end
        rescue Timeout::Error
          kill_node_child(wait_thr.pid)
          begin
            wait_thr.value
          rescue StandardError
            # Process may already be reaped or unavailable after a forced kill.
          end
          out_reader.kill if out_reader.alive?
          err_reader.kill if err_reader.alive?
          timed_out_err = "Critical CSS Node process timed out after #{timeout_sec}s and was killed"
          err = [err, timed_out_err].reject(&:empty?).join("\n")
          # Always return a non-zero exitstatus: signal-killed children often have nil exitstatus.
          [out, err, TimedOutStatus.new]
        end
      end
    end

    def kill_node_child(pid)
      return unless pid

      Process.kill('TERM', pid)
      sleep 0.5
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      # already exited
    end

    # Minimal stand-in when wait_thr.value is unavailable after a forced kill.
    class TimedOutStatus
      def exitstatus
        1
      end
    end
  end
end
