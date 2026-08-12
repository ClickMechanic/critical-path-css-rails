require 'spec_helper'
require 'open3'

RSpec.describe 'CssFetcher' do
  subject { CriticalPathCss::CssFetcher.new(config) }

  let(:base_url) { 'http://0.0.0.0:9292' }
  let(:response) { ['foo', '', instance_double(Process::Status, exitstatus: 0)] }
  let(:routes)   { ['/', '/new_route'] }
  let(:penthouse_options) { {} }
  let(:config) do
    CriticalPathCss::Configuration.new(
      {
        'base_url' => base_url,
        'css_paths' => css_paths,
        'penthouse_options' => penthouse_options,
        'routes' => routes
      }
    )
  end

  describe '#fetch_route' do
    context 'when a single css_path is configured' do
      let(:css_paths) { ['/test.css'] }

      it 'generates css for the single route' do
        expect(subject).to receive(:capture3_with_timeout) do |_timeout, arg1, arg2, arg3|
          expect(arg1).to eq('node')
          expect(arg2).to eq('lib/fetch-css.js')
          options = JSON.parse(arg3)

          expect(options['css']).to eq '/test.css'
          expect(options.dig('puppeteer', 'args')).to include(
            '--no-zygote',
            '--single-process',
            '--no-sandbox',
            '--disable-setuid-sandbox'
          )
        end.once.and_return(response)

        subject.fetch_route(routes.first)
      end

      it 'passes a default Ruby timeout buffer beyond the penthouse timeout' do
        expect(subject).to receive(:capture3_with_timeout) do |timeout, arg1, arg2, arg3|
          expect(timeout).to eq(
            30.0 + CriticalPathCss::CssFetcher::DEFAULT_NODE_TIMEOUT_BUFFER_SEC
          )
          expect(arg1).to eq('node')
          expect(arg2).to eq('lib/fetch-css.js')
          options = JSON.parse(arg3)
          expect(options).not_to have_key('node_timeout_buffer_sec')
          expect(options['node_hard_timeout_buffer_ms']).to eq(
            CriticalPathCss::CssFetcher::DEFAULT_NODE_HARD_TIMEOUT_BUFFER_MS
          )
          response
        end

        subject.fetch_route(routes.first)
      end
    end

    context 'when node_timeout_buffer_sec is configured' do
      let(:css_paths) { ['/test.css'] }
      let(:penthouse_options) { { 'node_timeout_buffer_sec' => 120 } }

      it 'uses the configured Ruby timeout buffer' do
        expect(subject).to receive(:capture3_with_timeout) do |timeout, _arg1, _arg2, arg3|
          expect(timeout).to eq(30.0 + 120)
          expect(JSON.parse(arg3)).not_to have_key('node_timeout_buffer_sec')
          response
        end

        subject.fetch_route(routes.first)
      end
    end

    context 'when other puppeteer options are configured' do
      let(:css_paths) { ['/test.css'] }
      let(:penthouse_options) do
        { 'puppeteer' => { 'pageGotoOptions' => { 'waitUntil' => 'networkidle0' } } }
      end

      it 'preserves default Chromium args alongside the custom puppeteer options' do
        expect(subject).to receive(:capture3_with_timeout) do |_timeout, _arg1, _arg2, arg3|
          options = JSON.parse(arg3)
          expect(options.dig('puppeteer', 'pageGotoOptions')).to eq('waitUntil' => 'networkidle0')
          expect(options.dig('puppeteer', 'args')).to include('--no-zygote', '--single-process')
          response
        end

        subject.fetch_route(routes.first)
      end
    end

    context 'when a custom penthouse timeout is configured' do
      let(:css_paths) { ['/test.css'] }
      let(:penthouse_options) { { 'timeout' => 2_000 } }

      it 'derives the Ruby kill timeout from the custom penthouse timeout' do
        expect(subject).to receive(:capture3_with_timeout) do |timeout, arg1, arg2, arg3|
          expect(timeout).to eq(
            2.0 + CriticalPathCss::CssFetcher::DEFAULT_NODE_TIMEOUT_BUFFER_SEC
          )
          expect(arg1).to eq('node')
          expect(arg2).to eq('lib/fetch-css.js')
          expect(arg3).to be_a(String)
          response
        end

        subject.fetch_route(routes.first)
      end
    end
  end

  describe '#fetch' do
    context 'when a single css_path is configured' do
      let(:css_paths) { ['/test.css'] }

      it 'generates css for each route from the same file' do
        expect(subject).to receive(:capture3_with_timeout) do |_timeout, _arg1, _arg2, arg3|
          options = JSON.parse(arg3)

          expect(options['css']).to eq '/test.css'
        end.twice.and_return(response)

        subject.fetch
      end
    end

    context 'when multiple css_paths are configured' do
      let(:css_paths) { ['/test.css', '/test2.css'] }

      it 'generates css for each route from the respective file' do
        expect(subject).to receive(:capture3_with_timeout) do |_timeout, _arg1, _arg2, arg3|
          options = JSON.parse(arg3)

          css_paths.each_with_index do |path, index|
            expect(options['css']).to eq path if options['url'] == "#{base_url}/#{routes[index]}"
          end
        end.twice.and_return(response)

        subject.fetch
      end
    end

    context 'when same css file applies to multiple routes' do
      let(:css_paths) { ['/test.css', '/test2.css', '/test.css'] }
      let(:routes) { ['/', '/new_route', '/newer_route'] }

      it 'generates css for each route from the respective file' do
        expect(subject).to receive(:capture3_with_timeout) do |_timeout, _arg1, _arg2, arg3|
          options = JSON.parse(arg3)

          css_paths.each_with_index do |path, index|
            expect(options['css']).to eq path if options['url'] == "#{base_url}/#{routes[index]}"
          end
        end.thrice.and_return(response)

        subject.fetch
      end
    end
  end

  describe '#capture3_with_timeout' do
    let(:css_paths) { ['/test.css'] }

    it 'kills a hung child process and returns a timeout error' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      out, err, status = subject.send(
        :capture3_with_timeout,
        1,
        'ruby',
        '-e',
        <<~'RUBY'
          $stdout.sync = true
          puts Process.pid
          sleep 60
        RUBY
      )

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      child_pid = out.to_i

      expect(elapsed).to be < 3
      expect(err).to include('Critical CSS Node process timed out after 1s and was killed')
      expect(status.exitstatus).to eq(1)
      expect(child_pid).to be > 0
      expect { Process.kill(0, child_pid) }.to raise_error(Errno::ESRCH)
    end

    it 'returns output from a child that finishes before the timeout' do
      out, err, status = subject.send(:capture3_with_timeout, 5, 'ruby', '-e', 'print "ok"')

      expect(out).to eq('ok')
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
    end
  end
end
