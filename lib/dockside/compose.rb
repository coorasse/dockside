module Dockside
  # Wraps `docker compose` for one project (one app in one environment).
  class Compose
    def initialize(project)
      @project = project
    end

    def config
      JSON.parse(run!(["config", "--format", "json"]).stdout)
    end

    def config_yaml
      run!(["config"]).stdout
    end

    def up(service, build: false, pull: false, timeout: 300)
      argv = ["up", "--detach", "--wait", "--wait-timeout", timeout.to_s]
      argv << "--build" if build
      argv += ["--pull", "always"] if pull
      run(argv + [service], stream: true)
    end

    def stop(service)
      run!(["stop", service])
    end

    def remove(service)
      run!(["rm", "--stop", "--force", "--volumes", service])
    end

    def down
      run!(["down"])
    end

    def exec(service, command, environment: {}, stdin: nil, workdir: nil, user: nil)
      argv = ["exec", "--no-TTY"]
      environment.each { |key, value| argv += ["--env", "#{key}=#{value}"] }
      argv += ["--workdir", workdir] if workdir
      argv += ["--user", user] if user
      run(argv + [service] + shell_words(command), stdin: stdin)
    end

    def logs(service, tail: 100, follow: false)
      argv = ["logs", "--no-color", "--tail", tail.to_s]
      argv << "--follow" if follow
      run(argv + [service], stream: follow)
    end

    def argv_prefix
      ["docker", "compose", "--project-name", @project.name, "--project-directory", @project.root.to_s] +
        @project.files.flat_map { |file| ["--file", file.to_s] }
    end

    private

    def shell_words(command)
      command.is_a?(Array) ? command : ["sh", "-c", command]
    end

    def run(argv, **options)
      @project.runner.run(argv_prefix + argv, env: @project.compose_env, **options)
    end

    def run!(argv, **options)
      @project.runner.run!(argv_prefix + argv, env: @project.compose_env, **options)
    end
  end
end
