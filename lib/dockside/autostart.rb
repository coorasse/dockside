module Dockside
  # Decides when the containers start on their own: with `rails server` in development,
  # before the first test in test.
  module Autostart
    def self.enabled?(config)
      return config.autostart unless config.autostart.nil?

      ENV["DOCKSIDE_AUTOSTART"] != "0"
    end

    def self.boot(config, env:, server_process:)
      install(env: env, server_process: server_process) if enabled?(config)
    end

    # rspec-rails defines RSpec in every process; only an rspec run loads RSpec.configure.
    def self.install(env:, server_process:, rspec: (::RSpec if defined?(::RSpec) && ::RSpec.respond_to?(:configure)))
      case env.to_s
      when "development"
        Dockside.ensure_running! if server_process
      when "test"
        install_test_hook(rspec)
      end
    end

    def self.install_test_hook(rspec)
      if rspec
        rspec.configure { |config| config.before(:suite) { Dockside.ensure_running! } }
      else
        ActiveSupport.on_load(:active_support_test_case) { Dockside.ensure_running! }
      end
    end
  end
end
