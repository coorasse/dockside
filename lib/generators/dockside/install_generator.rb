require "rails/generators"

module Dockside
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/dockside.yml with a commented example"

      def create_compose_file
        template "dockside.yml.tt", "config/dockside.yml"
      end
    end
  end
end
