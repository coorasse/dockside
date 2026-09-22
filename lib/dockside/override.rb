module Dockside
  # The compose override file the gem generates for one environment: the environment block of every
  # service plus the conventions (image tag for built services, host.docker.internal).
  class Override
    def initialize(project)
      @project = project
    end

    def to_hash
      services = @project.raw_services.to_h do |service, definition|
        [service, service_override(service, definition)]
      end
      {"services" => services}
    end

    def to_yaml
      tree = Psych::Visitors::YAMLTree.create
      tree << to_hash
      stream = tree.tree
      mark_environment_lists_as_override(stream.children.first.root)
      stream.to_yaml
    end

    private

    def service_override(service, definition)
      override = Settings.compose_overrides(definition, @project.env)
      override["extra_hosts"] = Array(override["extra_hosts"] || definition["extra_hosts"]) | [Project::HOST_GATEWAY]
      override["image"] = "#{@project.app_name}-#{service}" if definition.key?("build") && !definition.key?("image")
      override
    end

    def environment_keys(service)
      Settings.compose_overrides(@project.raw_services.fetch(service), @project.env).keys
    end

    # Lists in an environment block replace the list of the service instead of being appended to it.
    def mark_environment_lists_as_override(root)
      services = root.children.last
      services.children.each_slice(2) do |name, service|
        replaced = environment_keys(name.value)
        service.children.each_slice(2) do |key, value|
          next unless value.is_a?(Psych::Nodes::Sequence) && replaced.include?(key.value)

          value.tag = "!override"
          value.implicit = false
        end
      end
    end
  end
end
