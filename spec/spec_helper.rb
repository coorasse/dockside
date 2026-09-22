require "simplecov"

SimpleCov.start do
  skip "/spec/"
  enable_coverage :line
  # Only a full run has to reach 100%; a single spec file may be run on its own.
  minimum_coverage line: 100 if ARGV.empty?
end

require "dockside"
require "webmock/rspec"

Dir[File.join(__dir__, "support/**/*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = ".rspec_status"
  config.filter_run_excluding(docker: true) unless ENV["DOCKER"] == "1"

  config.include World
  config.include FakeDocker::Matchers

  config.before do
    Dockside.reset!
    Dockside.poll_interval = 0
    Dockside.output = StringIO.new
  end

  config.after do
    close_listening_servers
    Dockside.reset!
    Dockside.output = nil
    Dockside.poll_interval = 1
    FileUtils.rm_rf(@app_root) if @app_root
  end
end
