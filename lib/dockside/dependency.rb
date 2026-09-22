require "fileutils"

module Dockside
  # One service of the compose file in one environment: start, stop, reset, exec.
  class Dependency
    LOG_LINES_ON_ERROR = 50

    attr_reader :name, :project, :settings, :config

    def initialize(name:, project:, settings:, config:, shared: false)
      @name = name
      @project = project
      @settings = settings
      @config = config
      @shared = shared
    end

    def env
      project.env
    end

    def shared?
      @shared
    end

    def autostart?
      settings.autostart?
    end

    def port
      published = config.dig("ports", 0, "published")
      published&.to_s&.[](/\d+/)&.to_i
    end

    def container_port
      config.dig("ports", 0, "target")
    end

    def url
      "http://localhost:#{port}" if port
    end

    def container_name
      "#{project.name}-#{name}-1"
    end

    def running?
      container&.running? || false
    end

    def ready?
      running? && probe.ready?
    end

    def start(build: false, pull: false)
      with_lock do
        docker.preflight!
        create_bind_mount_directories
        return if !build && !pull && reuse_running_container

        Dockside.log "starting #{name} (#{env})"
        compose_up(build: build, pull: pull)
        wait_until_ready
        provisioner.run(container.id)
        remember_config
        Dockside.log "#{name} ready at #{url}"
      end
    end

    def ensure_running!
      start
    end

    def stop
      compose.stop(name)
    end

    def reset
      remove
      start
    end

    # Removes the container, its volumes and the content of its data folders under tmp/.
    def remove
      compose.remove(name)
      remove_shared_container
      named_volumes.each { |volume| docker.remove_volume(volume) }
      bind_mount_sources.select { |source| source.to_s.start_with?(project.root.join("tmp").to_s) }.each { |source| wipe(source) }
      FileUtils.rm_f(provisioner.marker)
    end

    def remove_shared_container
      return unless shared?

      other = docker.find_container(project: "#{project.app_name}-#{project.other_env}", service: name)
      docker.remove_container(other.id) if other
    end

    def exec(command, environment: {}, stdin: nil, workdir: nil, user: nil, allow_failure: false)
      result = compose.exec(name, command, environment: environment, stdin: stdin, workdir: workdir, user: user)
      raise CommandFailed.new(result) unless result.success? || allow_failure

      result.stdout
    end

    def exec_succeeds?(command)
      compose.exec(name, command).success?
    end

    def logs(tail: 100)
      compose.logs(name, tail: tail).stdout
    end

    def probe
      @probe ||= Readiness.probe_for(self, settings.ready)
    end

    def provisioner
      @provisioner ||= Provisioner.new(self)
    end

    private

    def compose
      project.compose
    end

    def docker
      project.docker
    end

    def container
      docker.find_container(project: project.name, service: name)
    end

    def with_lock
      project.work_dir.mkpath
      File.open(project.work_dir.join(".lock"), File::RDWR | File::CREAT) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    def reuse_running_container
      if !config_changed? && ready?
        Dockside.log "#{name} already running at #{url}"
        return true
      end
      return false unless shared?

      other = docker.find_container(project: "#{project.app_name}-#{project.other_env}", service: name)
      return false unless other&.running? && probe.ready?

      Dockside.log "#{name} shared with #{project.other_env} at #{url}"
      true
    end

    def compose_up(build:, pull:)
      result = compose.up(name, build: build, pull: pull, timeout: settings.timeout)
      return if result.success?

      output = result.stdout
      if output.match?(/port is already allocated|address already in use/i)
        raise PortInUse, "#{name} (#{env}) could not start because port #{port} is in use. " \
          "Run `docker ps` to see whether another container holds it.\n#{output}"
      end

      raise CommandFailed.new(result, "#{name} (#{env}) failed to start:\n#{output}\nLast #{LOG_LINES_ON_ERROR} log lines:\n#{last_logs}")
    end

    def wait_until_ready
      Readiness.wait(probe, timeout: settings.timeout)
    rescue ReadyTimeout
      raise ReadyTimeout, "#{name} (#{env}) did not become ready within #{settings.timeout}s " \
        "(waited until #{probe}). Last #{LOG_LINES_ON_ERROR} log lines:\n#{last_logs}"
    end

    def last_logs
      logs(tail: LOG_LINES_ON_ERROR).chomp
    end

    def config_file
      project.work_dir.join("#{name}.config.json")
    end

    def config_changed?
      !config_file.exist? || config_file.read != JSON.generate(config)
    end

    def remember_config
      config_file.write(JSON.generate(config))
    end

    def create_bind_mount_directories
      bind_mount_sources.select { |source| source.to_s.start_with?(project.root.to_s) }.each do |source|
        FileUtils.mkdir_p(source)
        FileUtils.chmod(0o777, source)
      end
    end

    # Empties the folder but keeps it: Docker Desktop keeps a deleted folder mounted as a stale mount.
    def wipe(directory)
      return unless directory.directory?

      directory.children.each { |child| FileUtils.rm_rf(child) }
    end

    def bind_mount_sources
      Array(config["volumes"]).select { |volume| volume["type"] == "bind" }.map { |volume| Pathname.new(volume["source"]) }
    end

    def named_volumes
      Array(config["volumes"]).select { |volume| volume["type"] == "volume" }.map { |volume| "#{project.name}_#{volume["source"]}" }
    end
  end
end
