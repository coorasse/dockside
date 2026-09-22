require "json"
require "pathname"
require "yaml"
require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/generators")
loader.ignore("#{__dir__}/tasks")
loader.ignore("#{__dir__}/dockside/railtie.rb")
loader.ignore("#{__dir__}/dockside/errors.rb")
loader.setup

require "dockside/errors"

# Starts the Docker containers an app needs, described in config/dockside.yml.
module Dockside
  class << self
    attr_writer :root, :env, :app_name, :runner, :output
    attr_accessor :poll_interval

    def root
      @root ||= Pathname.new((defined?(Rails) && Rails.root) ? Rails.root : Dir.pwd)
    end

    def env
      @env ||= (defined?(Rails) && Rails.env.present?) ? Rails.env.to_s : ENV.fetch("RAILS_ENV", "development")
    end

    def app_name
      @app_name ||= default_app_name
    end

    def runner
      @runner ||= Runner.new
    end

    def output
      @output || $stdout
    end

    def project
      @project ||= Project.new(root: root, env: env, app_name: app_name, runner: runner)
    end

    def registry
      @registry ||= Registry.new(project)
    end

    def reset!
      @root = @env = @app_name = @runner = @project = @registry = nil
    end

    def names
      registry.names
    end

    def fetch(name)
      registry.fetch(name)
    end

    def ensure_running!(*names)
      dependencies = names.empty? ? registry.autostart : names.map { |name| fetch(name) }
      dependencies.each(&:ensure_running!)
    end

    def down
      registry.each(&:remove_shared_container)
      project.compose.down
    end

    def log(message)
      output.puts("dockside: #{message}")
    end

    def respond_to_missing?(name, include_private = false)
      registry.names.include?(name) || super
    end

    def method_missing(name, *args)
      if args.empty? && registry.names.include?(name)
        fetch(name)
      else
        super
      end
    end

    private

    def default_app_name
      if defined?(Rails) && Rails.application
        Rails.application.class.module_parent_name.underscore.dasherize
      else
        root.basename.to_s.downcase.tr("_ ", "--")
      end
    end
  end
end

Dockside.poll_interval = 1

require "dockside/railtie" if defined?(Rails::Railtie)
