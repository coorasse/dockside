module Dockside
  class Error < StandardError; end

  class ConfigError < Error; end

  class UnknownDependency < Error; end

  class DockerMissing < Error; end

  class DockerUnavailable < Error; end

  class ComposeMissing < Error; end

  class ReadyTimeout < Error; end

  class PortInUse < Error; end

  class CommandFailed < Error
    attr_reader :argv, :stdout, :stderr, :exit_status

    def initialize(result, message = nil)
      @argv = result.argv
      @stdout = result.stdout
      @stderr = result.stderr
      @exit_status = result.exit_status
      super(message || default_message)
    end

    # The last lines the command printed, stderr first.
    def output_tail(lines = 10)
      [stderr, stdout].map(&:strip).reject(&:empty?).join("\n").lines.last(lines).join.strip
    end

    private

    def default_message
      message = "`#{argv.join(" ")}` failed with status #{exit_status}"
      details = [stderr, stdout].map(&:strip).reject(&:empty?).join("\n")
      details.empty? ? message : "#{message}:\n#{details}"
    end
  end
end
