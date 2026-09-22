require "rails"
require "action_controller/railtie"
require "dockside"
require "dockside/railtie"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "dummy"
    config.dockside.autostart = false
  end
end
