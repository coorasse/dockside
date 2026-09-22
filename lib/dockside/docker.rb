module Dockside
  # The docker commands the gem needs besides compose: checks, container lookup, removal.
  class Docker
    Container = Struct.new(:id, :state) do
      def running?
        state == "running"
      end
    end

    def initialize(runner)
      @runner = runner
      @checked = false
    end

    def preflight!
      return if @checked

      check_daemon
      check_compose
      @checked = true
    end

    # The container compose created for the service in the project, or nil.
    def find_container(project:, service:)
      result = @runner.run!([
        "docker", "ps", "--all",
        "--filter", "label=com.docker.compose.project=#{project}",
        "--filter", "label=com.docker.compose.service=#{service}",
        "--format", "{{.ID}} {{.State}}"
      ])
      id, state = result.stdout.lines.first&.split
      Container.new(id, state) if id
    end

    def remove_container(id)
      @runner.run!(["docker", "rm", "--force", "--volumes", id])
    end

    def remove_volume(name)
      @runner.run!(["docker", "volume", "rm", "--force", name])
    end

    private

    def check_daemon
      result = @runner.run(["docker", "version", "--format", "{{.Server.Version}}"])
      return if result.success?

      raise DockerUnavailable, "Docker is installed but the daemon does not answer: #{result.stderr.strip}\n" \
        "Start Docker, or start with DOCKSIDE_AUTOSTART=0 to skip the containers."
    end

    def check_compose
      result = @runner.run(["docker", "compose", "version"])
      return if result.success?

      raise ComposeMissing, "The docker compose plugin is missing. Install it from " \
        "https://docs.docker.com/compose/install/ (docker-compose v1 is not supported)."
    end
  end
end
