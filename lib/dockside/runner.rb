require "open3"

module Dockside
  # Runs commands given as argv arrays, never as shell strings.
  class Runner
    Result = Struct.new(:argv, :stdout, :stderr, :exit_status) do
      def success?
        exit_status.zero?
      end
    end

    # Returns a Result. With stream: true the output is also printed while the command runs.
    def run(argv, env: {}, stdin: nil, chdir: nil, stream: false)
      if stream
        stream_run(argv, env: env, chdir: chdir)
      else
        capture_run(argv, env: env, stdin: stdin, chdir: chdir)
      end
    rescue Errno::ENOENT
      raise DockerMissing, "#{argv.first} was not found. Install Docker with the Compose plugin " \
        "(https://docs.docker.com/get-docker/) or start with DOCKSIDE_AUTOSTART=0 to skip the containers."
    end

    def run!(argv, **options)
      result = run(argv, **options)
      raise CommandFailed.new(result) unless result.success?

      result
    end

    private

    def capture_run(argv, env:, stdin:, chdir:)
      options = {}
      options[:chdir] = chdir.to_s if chdir
      options[:stdin_data] = stdin if stdin
      stdout, stderr, status = Open3.capture3(env, *argv, **options)
      Result.new(argv: argv, stdout: stdout, stderr: stderr, exit_status: status.exitstatus)
    end

    def stream_run(argv, env:, chdir:)
      options = {}
      options[:chdir] = chdir.to_s if chdir
      output = +""
      Open3.popen2e(env, *argv, **options) do |input, combined, wait|
        input.close
        combined.each_line do |line|
          Dockside.output.print(line)
          output << line
        end
        Result.new(argv: argv, stdout: output, stderr: "", exit_status: wait.value.exitstatus)
      end
    end
  end
end
