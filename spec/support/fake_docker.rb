# A stand-in for Dockside::Runner that pretends to be the Docker daemon.
#
# It answers the docker and docker compose commands the gem runs and keeps track of the containers those
# commands would create, so a spec can say "the container is running" and check "compose up was not called".
# `docker compose config` is the one command that reaches the real compose CLI, because it only parses files.
#
# Any command can be overridden with `on`, for example to make `compose up` fail.
class FakeDocker
  Call = Struct.new(:argv, :env, :stdin, :chdir) do
    def to_s
      argv.join(" ")
    end

    # Every fragment has to appear as whole words: "up" does not match "local/uploads".
    def includes?(*fragments)
      fragments.all? { |fragment| to_s.match?(/(?<!\S)#{Regexp.escape(fragment)}(?!\S)/) }
    end
  end

  Container = Struct.new(:id, :project, :service, :state) do
    def running?
      state == "running"
    end
  end

  Stub = Struct.new(:fragments, :stdout, :stderr, :exit_status, :block) do
    def answer(call)
      answer = block&.call(call)
      answer.is_a?(Dockside::Runner::Result) ? answer : result_for(call, answer)
    end

    def result_for(call, block_output)
      Dockside::Runner::Result.new(argv: call.argv, stdout: block_output || stdout, stderr: stderr, exit_status: exit_status)
    end
  end

  attr_reader :calls, :containers

  def initialize
    @calls = []
    @containers = []
    @stubs = []
    @logs = {}
    @installed = true
    @daemon_running = true
    @compose_installed = true
    @next_id = 0
  end

  # --- setting the scene -----------------------------------------------------------------------------

  def not_installed!
    @installed = false
  end

  def daemon_down!
    @daemon_running = false
  end

  def compose_missing!
    @compose_installed = false
  end

  # Like compose, keeps the id of an existing container of the service unless it is recreated.
  def add_container(project:, service:, state: "running", id: nil, recreate: false)
    existing = container_of(project: project, service: service)
    id ||= (existing && !recreate) ? existing.id : next_id
    @containers.delete(existing)
    Container.new(id: id, project: project, service: service, state: state).tap { |container| @containers << container }
  end

  def container_of(project:, service:)
    @containers.find { |container| container.project == project && container.service == service }
  end

  def logs_of(project:, service:, text:)
    @logs[[project, service]] = text
  end

  # Answers every command whose words include all fragments, taking precedence over the simulation.
  # A block receives the call and returns the stdout, or a whole Runner::Result.
  def on(*fragments, stdout: "", stderr: "", exit_status: 0, &block)
    @stubs << Stub.new(fragments: fragments, stdout: stdout, stderr: stderr, exit_status: exit_status, block: block)
  end

  # Runs the block once compose started the service, for example to open the port it publishes.
  def after_starting(service, &block)
    on("up", service.to_s) { |call| simulate(call).tap { block.call } }
  end

  # --- what the gem sees -----------------------------------------------------------------------------

  def runs_of(*fragments)
    @calls.select { |call| call.includes?(*fragments) }
  end

  def run(argv, env: {}, stdin: nil, chdir: nil, stream: false)
    raise Dockside::DockerMissing, "docker was not found" unless @installed

    call = Call.new(argv: argv, env: env, stdin: stdin, chdir: chdir)
    @calls << call
    return real_command(call) unless argv.first == "docker"

    stub = @stubs.reverse.find { |candidate| call.includes?(*candidate.fragments) }
    stub ? stub.answer(call) : simulate(call)
  end

  def run!(argv, **options)
    result = run(argv, **options)
    raise Dockside::CommandFailed.new(result) unless result.success?

    result
  end

  private

  def next_id
    @next_id += 1
    format("c0ffee%02d", @next_id)
  end

  def simulate(call)
    words = call.to_s
    case words
    when /\Adocker version/ then daemon_answer(call)
    when /\Adocker compose version/ then compose_version_answer(call)
    when / config( --format json)?\z/ then real_compose(call)
    when / up .* (\S+)\z/ then compose_up(call, Regexp.last_match(1))
    when / stop (\S+)\z/ then change_state(call, Regexp.last_match(1), "exited")
    when / rm --stop --force --volumes (\S+)\z/ then remove_service(call, Regexp.last_match(1))
    when / down\z/ then remove_project(call)
    when / exec --no-TTY / then success(call)
    when / logs --no-color --tail \d+(?: --follow)? (\S+)\z/ then success(call, stdout: @logs.fetch([project_of(call), Regexp.last_match(1)], ""))
    when /\Adocker ps --all/ then docker_ps(call)
    when /\Adocker rm --force --volumes (\S+)\z/ then remove_container(call, Regexp.last_match(1))
    when /\Adocker volume rm/ then success(call)
    else raise "FakeDocker does not know how to answer `#{words}`"
    end
  end

  def daemon_answer(call)
    return success(call, stdout: "29.0.0\n") if @daemon_running

    failure(call, stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
  end

  def compose_version_answer(call)
    return success(call, stdout: "Docker Compose version v5.0.0\n") if @compose_installed

    failure(call, stderr: "docker: 'compose' is not a docker command.")
  end

  def real_compose(call)
    Dockside::Runner.new.run(call.argv, env: call.env)
  end

  def real_command(call)
    Dockside::Runner.new.run(call.argv, env: call.env, stdin: call.stdin, chdir: call.chdir)
  end

  def compose_up(call, service)
    container = add_container(project: project_of(call), service: service)
    success(call, stdout: " ✔ Container #{project_of(call)}-#{service}-1  Started (#{container.id})\n")
  end

  def change_state(call, service, state)
    container_of(project: project_of(call), service: service)&.state = state
    success(call)
  end

  def remove_service(call, service)
    @containers.reject! { |container| container.project == project_of(call) && container.service == service }
    success(call)
  end

  def remove_project(call)
    @containers.reject! { |container| container.project == project_of(call) }
    success(call)
  end

  def remove_container(call, id)
    @containers.reject! { |container| container.id == id }
    success(call)
  end

  def docker_ps(call)
    project = call.argv[call.argv.index { |word| word.start_with?("label=com.docker.compose.project=") }].split("=").last
    service = call.argv[call.argv.index { |word| word.start_with?("label=com.docker.compose.service=") }].split("=").last
    container = container_of(project: project, service: service)
    success(call, stdout: container ? "#{container.id} #{container.state}\n" : "")
  end

  def project_of(call)
    call.argv[call.argv.index("--project-name") + 1]
  end

  def success(call, stdout: "")
    Dockside::Runner::Result.new(argv: call.argv, stdout: stdout, stderr: "", exit_status: 0)
  end

  def failure(call, stderr:)
    Dockside::Runner::Result.new(argv: call.argv, stdout: "", stderr: stderr, exit_status: 1)
  end

  module Matchers
    extend RSpec::Matchers::DSL

    matcher :have_run do |*fragments|
      match { |docker| docker.runs_of(*fragments).any? }

      failure_message do |docker|
        "expected a command containing #{fragments.map(&:inspect).join(" and ")}, but docker only ran:\n" +
          docker.calls.map { |call| "  #{call}" }.join("\n")
      end

      failure_message_when_negated do |docker|
        "expected no command containing #{fragments.map(&:inspect).join(" and ")}, but docker ran:\n" +
          docker.runs_of(*fragments).map { |call| "  #{call}" }.join("\n")
      end
    end
  end
end
