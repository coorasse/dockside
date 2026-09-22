module Dockside
  # All dependencies of the app for one environment, built once from the resolved compose file.
  class Registry
    include Enumerable

    def initialize(project)
      @project = project
      @dependencies = build
    end

    def names
      @dependencies.keys
    end

    def fetch(name)
      @dependencies.fetch(name.to_sym) do
        raise UnknownDependency, "Unknown dependency #{name}. Known: #{names.join(", ")}."
      end
    end
    alias_method :[], :fetch

    def each(&block)
      @dependencies.each_value(&block)
    end

    def autostart
      select(&:autostart?)
    end

    private

    def build
      resolved = @project.resolve!
      @project.service_names.to_h do |service|
        dependency = Dependency.new(
          name: service,
          project: @project,
          settings: @project.settings(service),
          config: resolved.fetch(service),
          shared: shared?(service)
        )
        [service.to_sym, dependency]
      end
    end

    def shared?(service)
      port = @project.host_port(service, @project.env)
      return false if port.nil? || port != @project.host_port(service, @project.other_env)

      Dockside.log "warning: #{service} uses port #{port} in development and test, " \
        "so both environments share one container and its data"
      true
    end
  end
end
