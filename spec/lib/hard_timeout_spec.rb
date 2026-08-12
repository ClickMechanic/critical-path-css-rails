require 'spec_helper'
require 'open3'

RSpec.describe 'Node hard timeout helper' do
  it 'rejects a never-resolving promise without hanging' do
    script = File.expand_path('../js/hard_timeout_test.js', __dir__)
    stdout, stderr, status = Open3.capture3('node', script)

    expect(status.exitstatus).to eq(0), "stdout=#{stdout}\nstderr=#{stderr}"
    expect(stdout).to include('hard_timeout_test: ok')
  end
end
