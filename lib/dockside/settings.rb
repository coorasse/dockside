module Dockside
  # The x-dockside part of a service, merged for one environment.
  Settings = Struct.new(:ready, :timeout, :after_start, :autostart)

  class Settings
    KEYS = %w[ready timeout after_start autostart].freeze
    DEFAULTS = {"ready" => "auto", "timeout" => 300, "after_start" => [], "autostart" => true}.freeze

    def self.for(service, definition, env)
      extension = definition["x-dockside"] || {}
      environment_block = extension[env] || {}
      values = DEFAULTS.merge(extension.slice(*KEYS)).merge(environment_block.slice(*KEYS))
      new(**values.transform_keys(&:to_sym)).tap do |settings|
        settings.after_start = Provisioner::Step.parse_all(service, settings.after_start)
      end
    end

    def self.validate(service, extension)
      return if extension.nil?

      unknown = extension.keys - KEYS - Project::ENVIRONMENTS
      return if unknown.empty?

      raise ConfigError, "Unknown x-dockside key#{"s" if unknown.size > 1} #{unknown.join(", ")} for service #{service}. " \
        "Allowed: #{(KEYS + Project::ENVIRONMENTS).join(", ")}."
    end

    # The compose keys of the environment block, the part compose has to merge.
    def self.compose_overrides(definition, env)
      block = definition.dig("x-dockside", env) || {}
      block.except(*KEYS)
    end

    def autostart?
      autostart != false
    end
  end
end
