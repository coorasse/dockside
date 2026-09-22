RSpec.describe Dockside::Readiness, "waiting until a service is ready" do
  let(:port) { a_free_port }

  def dependency_with(ready)
    given_the_compose_file <<~YAML, env: "test"
      services:
        web:
          image: nginx
          ports: ["#{port}:80"]
          x-dockside:
            ready: #{ready}
    YAML
    Dockside.web
  end

  describe "the default (auto)" do
    it "is ready once the first published port accepts a connection and keeps it open" do
      probe = dependency_with("auto").probe

      expect(probe).to be_a(Dockside::Readiness::Tcp)
      expect(probe.ready?).to be(false)
      a_server_listening_on(port)
      expect(probe.ready?).to be(true)
    end

    it "is ready when the service greets with a banner, like a mail or database server" do
      probe = dependency_with("auto").probe
      a_server_listening_on(port) { |connection| connection.write("220 mailpit ESMTP\r\n") }

      expect(probe.ready?).to be(true)
    end

    it "is not ready while Docker accepts the connection but closes it, because nothing listens inside yet" do
      probe = dependency_with("auto").probe
      a_server_listening_on(port) { |connection| connection.close }

      expect(probe.ready?).to be(false)
    end

    it "only needs the container to run when the service publishes no port" do
      given_the_compose_file("services:\n  worker:\n    image: alpine\n")

      expect(Dockside.worker.probe).to be_a(Dockside::Readiness::None)
      expect(Dockside.worker.probe.ready?).to be(true)
    end
  end

  describe "ready: none" do
    it "waits for nothing beyond the container running" do
      probe = dependency_with("none").probe

      expect(probe).to be_a(Dockside::Readiness::None)
      expect(probe.to_s).to eq("container is running")
    end
  end

  describe "ready: { http: }" do
    it "is ready when the URL answers, with any status" do
      probe = dependency_with('{ http: "/health" }').probe
      stub_request(:get, "http://localhost:#{port}/health").to_return(status: 503)

      expect(probe.ready?).to be(true)
      expect(probe.to_s).to eq("http://localhost:#{port}/health answers")
    end

    it "wants the given status when one is configured" do
      probe = dependency_with('{ http: "/health", status: 200 }').probe
      stub_request(:get, "http://localhost:#{port}/health").to_return(status: 503)

      expect(probe.ready?).to be(false)
      expect(probe.to_s).to eq("http://localhost:#{port}/health answers with status 200")
    end

    it "is not ready while the connection is refused or times out" do
      probe = dependency_with('{ http: "/health" }').probe
      stub_request(:get, "http://localhost:#{port}/health").to_raise(Errno::ECONNREFUSED)
      expect(probe.ready?).to be(false)

      stub_request(:get, "http://localhost:#{port}/health").to_timeout
      expect(probe.ready?).to be(false)
    end
  end

  describe "ready: { log: }" do
    it "is ready when the container log matches the regular expression" do
      probe = dependency_with('{ log: "Listening on .*:80" }').probe

      the_container_log_says(:web, "booting\n")
      expect(probe.ready?).to be(false)

      the_container_log_says(:web, "booting\nListening on 0.0.0.0:80\n")
      expect(probe.ready?).to be(true)
      expect(probe.to_s).to eq("log matches Listening on .*:80")
    end
  end

  describe "ready: { command: }" do
    it "is ready when the command succeeds inside the container" do
      probe = dependency_with('{ command: ["pg_isready", "-U", "postgres"] }').probe

      docker.on("exec", "pg_isready", exit_status: 1)
      expect(probe.ready?).to be(false)

      docker.on("exec", "pg_isready", exit_status: 0)
      expect(probe.ready?).to be(true)
      expect(probe.to_s).to eq("command pg_isready -U postgres succeeds")
    end
  end

  describe "an unknown ready value" do
    it "is refused" do
      expect { dependency_with("sometime").probe }.to raise_error(Dockside::ConfigError, /ready must be auto, none/)
    end

    it "falls back to auto for an empty hash" do
      expect(dependency_with("{}").probe).to be_a(Dockside::Readiness::Tcp)
    end
  end

  describe ".wait" do
    let(:probe) { instance_double(Dockside::Readiness::Tcp) }

    it "polls the probe until it answers" do
      allow(probe).to receive(:ready?).and_return(false, false, true)

      described_class.wait(probe, timeout: 10)

      expect(probe).to have_received(:ready?).exactly(3).times
    end

    it "raises ReadyTimeout when the time runs out" do
      allow(probe).to receive(:ready?).and_return(false)

      expect { described_class.wait(probe, timeout: 0) }.to raise_error(Dockside::ReadyTimeout)
    end
  end
end
