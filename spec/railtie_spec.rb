require "rails_helper"

RSpec.describe Dockside::Railtie, "inside a Rails app" do
  it "takes the app name, the root and the environment from Rails" do
    Dockside.reset!

    expect(Dockside.app_name).to eq("dummy")
    expect(Dockside.root).to eq(Rails.root)
    expect(Dockside.env).to eq("test")
  end

  it "offers config.dockside" do
    expect(Rails.configuration.dockside).to respond_to(:autostart)
  end

  it "adds the dockside rake tasks" do
    load_the_rake_tasks

    expect(Rake::Task.tasks.map(&:name)).to include("dockside:up", "dockside:stop", "dockside:down", "dockside:reset",
      "dockside:status", "dockside:logs", "dockside:config")
  end

  it "finds the containers of the app in config/dockside.yml" do
    Dockside.reset!
    Dockside.runner = docker

    expect(Dockside.names).to eq([:echo])
    expect(Dockside.echo.port).to eq(5679)
    expect(Dockside.echo.container_name).to eq("dummy-test-echo-1")
  end
end

# Records the hooks RSpec.configure would register, so the spec can run them on purpose.
class FakeRSpec
  def initialize
    @suite_hooks = []
  end

  def configure
    yield self
  end

  def before(scope, &block)
    @suite_hooks << block if scope == :suite
  end

  def run_suite_hooks
    @suite_hooks.each(&:call)
  end
end

RSpec.describe Dockside::Autostart, "when the containers start on their own" do
  describe ".enabled?" do
    let(:config) { ActiveSupport::OrderedOptions.new }

    it "is on by default" do
      expect(described_class.enabled?(config)).to be(true)
    end

    it "is off with DOCKSIDE_AUTOSTART=0" do
      stub_const("ENV", ENV.to_h.merge("DOCKSIDE_AUTOSTART" => "0"))

      expect(described_class.enabled?(config)).to be(false)
    end

    it "follows config.dockside.autostart when the app sets it" do
      config.autostart = false
      expect(described_class.enabled?(config)).to be(false)

      config.autostart = true
      stub_const("ENV", ENV.to_h.merge("DOCKSIDE_AUTOSTART" => "0"))
      expect(described_class.enabled?(config)).to be(true)
    end
  end

  describe ".boot" do
    before { allow(Dockside).to receive(:ensure_running!) }

    it "installs nothing when autostart is off" do
      config = ActiveSupport::OrderedOptions.new
      config.autostart = false

      described_class.boot(config, env: "development", server_process: true)

      expect(Dockside).not_to have_received(:ensure_running!)
    end

    it "installs the hooks when autostart is on" do
      described_class.boot(ActiveSupport::OrderedOptions.new, env: "development", server_process: true)

      expect(Dockside).to have_received(:ensure_running!)
    end
  end

  describe ".install" do
    before { allow(Dockside).to receive(:ensure_running!) }

    context "in development" do
      it "starts the containers when the process is `rails server`" do
        described_class.install(env: "development", server_process: true)

        expect(Dockside).to have_received(:ensure_running!)
      end

      it "starts nothing for the console, runner and rake" do
        described_class.install(env: "development", server_process: nil)

        expect(Dockside).not_to have_received(:ensure_running!)
      end
    end

    context "in test with RSpec" do
      let(:rspec) { FakeRSpec.new }

      it "starts the containers before the first example, not while the app boots" do
        described_class.install(env: "test", server_process: nil, rspec: rspec)
        expect(Dockside).not_to have_received(:ensure_running!)

        rspec.run_suite_hooks

        expect(Dockside).to have_received(:ensure_running!)
      end
    end

    context "in test with Minitest" do
      it "starts the containers when ActiveSupport::TestCase loads" do
        require "active_support/test_case"

        described_class.install(env: "test", server_process: nil, rspec: nil)

        expect(Dockside).to have_received(:ensure_running!)
      end
    end

    context "in test from a rake task, where rspec-rails defines RSpec but no suite runs" do
      it "falls back to the Minitest hook instead of calling RSpec.configure" do
        require "active_support/test_case"
        allow(RSpec).to receive(:respond_to?).and_call_original
        allow(RSpec).to receive(:respond_to?).with(:configure).and_return(false)

        described_class.install(env: "test", server_process: nil)

        expect(Dockside).to have_received(:ensure_running!)
      end
    end

    context "in production" do
      it "does nothing" do
        described_class.install(env: "production", server_process: true)

        expect(Dockside).not_to have_received(:ensure_running!)
      end
    end
  end
end
