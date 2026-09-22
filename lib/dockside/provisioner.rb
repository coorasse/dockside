module Dockside
  # Runs the after_start steps of a dependency once per container.
  class Provisioner
    Step = Struct.new(:exec, :run, :environment, :workdir, :user, :stdin, :allow_failure, :always)

    class Step
      KEYS = %w[exec run environment workdir user stdin allow_failure always].freeze

      def self.parse_all(service, steps)
        Array(steps).map { |step| parse(service, step) }
      end

      def self.parse(service, step)
        unless step.is_a?(Hash) && (step.keys - KEYS).empty? && [step["exec"], step["run"]].compact.one?
          raise ConfigError, "#{service}: every after_start step needs exec: or run:, " \
            "with the options #{(KEYS - %w[exec run]).join(", ")}. Got #{step.inspect}"
        end

        new(**step.transform_keys(&:to_sym))
      end

      def description
        exec ? "exec #{Array(exec).join(" ")}" : "run #{Array(run).join(" ")}"
      end
    end

    def initialize(dependency)
      @dependency = dependency
    end

    def marker
      @dependency.project.work_dir.join("#{@dependency.name}.provisioned")
    end

    def provisioned?(container_id)
      marker.exist? && marker.read.strip == container_id
    end

    # Runs every step for a new container, only the `always` steps for a known one.
    def run(container_id)
      due = !provisioned?(container_id)
      @dependency.settings.after_start.each do |step|
        run_step(step) if due || step.always
      end
      marker.write(container_id) if due
    end

    private

    def run_step(step)
      Dockside.log "#{@dependency.name}: #{step.description}"
      environment = injected_environment.merge((step.environment || {}).transform_keys(&:to_s))
      stdin = step.stdin && @dependency.project.root.join(step.stdin).read
      if step.exec
        @dependency.exec(step.exec, environment: environment, stdin: stdin, workdir: step.workdir, user: step.user)
      else
        run_on_host(step, environment, stdin)
      end
    rescue CommandFailed => error
      raise unless step.allow_failure

      Dockside.log "#{@dependency.name}: the step failed, moving on because of allow_failure:\n#{error.output_tail}"
    end

    def run_on_host(step, environment, stdin)
      command = step.run.is_a?(Array) ? step.run : ["sh", "-c", step.run]
      result = @dependency.project.runner.run(command, env: environment, stdin: stdin, chdir: @dependency.project.root)
      raise CommandFailed.new(result) unless result.success?
    end

    def injected_environment
      {
        "DOCKSIDE_NAME" => @dependency.name,
        "DOCKSIDE_ENV" => @dependency.env,
        "DOCKSIDE_PORT" => @dependency.port.to_s,
        "DOCKSIDE_URL" => @dependency.url.to_s,
        "DOCKSIDE_CONTAINER" => @dependency.container_name
      }
    end
  end
end
