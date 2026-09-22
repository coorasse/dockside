require "rails/railtie"

module Dockside
  class Railtie < Rails::Railtie
    config.dockside = ActiveSupport::OrderedOptions.new
    config.dockside.autostart = nil

    rake_tasks do
      load File.expand_path("../tasks/dockside.rake", __dir__)
    end

    config.after_initialize do |app|
      Autostart.boot(app.config.dockside, env: Rails.env, server_process: defined?(Rails::Server))
    end
  end
end
