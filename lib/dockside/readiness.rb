require "net/http"
require "socket"

module Dockside
  # Probes that tell whether a started container really answers.
  module Readiness
    def self.probe_for(dependency, spec)
      case spec
      when "auto" then dependency.port ? Tcp.new(dependency.port) : None.new
      when "none" then None.new
      when Hash then probe_from_hash(dependency, spec)
      else raise ConfigError, "#{dependency.name}: ready must be auto, none, {http:}, {log:} or {command:}, got #{spec.inspect}"
      end
    end

    def self.probe_from_hash(dependency, spec)
      if spec.key?("http")
        Http.new("#{dependency.url}#{spec["http"]}", status: spec["status"])
      elsif spec.key?("log")
        Log.new(dependency, spec["log"])
      elsif spec.key?("command")
        Command.new(dependency, spec["command"])
      else
        probe_for(dependency, "auto")
      end
    end

    # Polls the probe until it answers. Raises ReadyTimeout, whose message the caller enriches with logs.
    def self.wait(probe, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until probe.ready?
        raise ReadyTimeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep Dockside.poll_interval
      end
    end

    class Tcp
      def initialize(port)
        @port = port
      end

      # Docker accepts connections on a published port before the service inside listens and closes
      # them right away, so a connection only counts when it stays open or the service says something.
      def ready?
        Socket.tcp("127.0.0.1", @port, connect_timeout: 1) do |socket|
          return true unless socket.wait_readable(0.2)

          !socket.read_nonblock(1, exception: false).nil?
        end
      rescue SystemCallError, IOError
        false
      end

      def to_s
        "port #{@port} accepts connections"
      end
    end

    class Http
      def initialize(url, status: nil)
        @uri = URI(url)
        @status = status
      end

      def ready?
        response = Net::HTTP.start(@uri.host, @uri.port, open_timeout: 1, read_timeout: 5) do |http|
          http.get(@uri.request_uri)
        end
        @status.nil? || response.code.to_i == @status
      rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
        false
      end

      def to_s
        "#{@uri} answers#{" with status #{@status}" if @status}"
      end
    end

    class Log
      def initialize(dependency, pattern)
        @dependency = dependency
        @pattern = Regexp.new(pattern)
      end

      def ready?
        @dependency.logs(tail: 200).match?(@pattern)
      end

      def to_s
        "log matches #{@pattern.source}"
      end
    end

    class Command
      def initialize(dependency, command)
        @dependency = dependency
        @command = command
      end

      def ready?
        @dependency.exec_succeeds?(@command)
      end

      def to_s
        "command #{Array(@command).join(" ")} succeeds"
      end
    end

    class None
      def ready?
        true
      end

      def to_s
        "container is running"
      end
    end
  end
end
