module Dockside
  # The app's compose file and the files the gem derives from it for one environment.
  class Project
    ENVIRONMENTS = %w[development test].freeze
    HOST_GATEWAY = "host.docker.internal:host-gateway".freeze

    attr_reader :root, :env, :app_name, :runner

    def initialize(root:, env:, app_name:, runner:)
      @root = Pathname.new(root)
      @env = env.to_s
      @app_name = app_name
      @runner = runner
    end

    def name
      "#{app_name}-#{env}"
    end

    def other_env
      (env == "test") ? "development" : "test"
    end

    def compose_file
      root.join("config/dockside.yml")
    end

    def env_file
      file = root.join("config/dockside.#{env}.yml")
      file if file.exist?
    end

    def work_dir
      root.join("tmp/dockside", env)
    end

    def override_file
      work_dir.join("override.yml")
    end

    # The app's compose file without the x-dockside part, so compose does not interpolate
    # ${...} inside after_start commands or warn about them.
    def plain_file
      work_dir.join("dockside.yml")
    end

    def files
      [plain_file, env_file, override_file].compact
    end

    def compose_env
      {"RAILS_ENV" => env, "DOCKSIDE_ENV" => env}
    end

    def compose
      @compose ||= Compose.new(self)
    end

    def docker
      @docker ||= Docker.new(runner)
    end

    def service_names
      raw_services.keys
    end

    def settings(service)
      Settings.for(service, raw_services.fetch(service), env)
    end

    # The first host port the service publishes in the given environment, read from the file
    # before compose resolves it. Used to find out whether two environments share a container.
    def host_port(service, environment)
      definition = raw_services.fetch(service)
      ports = definition.dig("x-dockside", environment, "ports") || definition["ports"] || []
      first = ports.first
      return if first.nil?

      published = first.is_a?(Hash) ? first["published"] : first.to_s.split(":")[-2]
      published&.to_s
    end

    # Writes the gem's files and lets compose merge everything. Returns the resolved services.
    def resolve!
      write_files
      compose.config.fetch("services")
    end

    # The compose file with everything merged, ready for a plain `docker compose -f`.
    def resolved_yaml
      write_files
      compose.config_yaml
    end

    def write_files
      work_dir.mkpath
      plain_file.write(plain_document.to_yaml)
      override_file.write(Override.new(self).to_yaml)
    end

    def raw_services
      raw_document.fetch("services")
    end

    private

    def raw_document
      @raw_document ||= load_raw_document
    end

    def load_raw_document
      raise ConfigError, "#{compose_file} does not exist. Run `bin/rails generate dockside:install`." unless compose_file.exist?

      document = YAML.safe_load(compose_file.read, aliases: true) || {}
      document["services"] ||= {}
      document["services"].each { |service, definition| validate(service, definition) }
      document
    end

    def plain_document
      services = raw_services.transform_values { |definition| definition.except("x-dockside") }
      raw_document.merge("services" => services)
    end

    def validate(service, definition)
      if definition.key?("container_name")
        raise ConfigError, "Service #{service} sets container_name. dockside names containers " \
          "#{app_name}-<environment>-#{service}-1, remove container_name."
      end
      Settings.validate(service, definition["x-dockside"])
    end
  end
end
