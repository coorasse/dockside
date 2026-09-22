RSpec.describe Dockside::Docker, "talking to the docker daemon" do
  subject(:daemon) { described_class.new(docker) }

  describe "#preflight!" do
    it "checks the daemon and the compose plugin only once" do
      daemon.preflight!
      daemon.preflight!

      expect(docker.calls.map(&:to_s)).to eq(["docker version --format {{.Server.Version}}", "docker compose version"])
    end
  end

  describe "#find_container" do
    it "finds the container compose created for a service, with its state" do
      docker.add_container(project: "my-app-test", service: "minio", state: "exited", id: "abc123")

      container = daemon.find_container(project: "my-app-test", service: "minio")

      expect(container.id).to eq("abc123")
      expect(container).not_to be_running
      expect(docker).to have_run("docker ps --all --filter label=com.docker.compose.project=my-app-test " \
        "--filter label=com.docker.compose.service=minio --format {{.ID}} {{.State}}")
    end

    it "returns nil when there is none" do
      expect(daemon.find_container(project: "my-app-test", service: "minio")).to be_nil
    end
  end

  it "removes containers and volumes by force" do
    docker.add_container(project: "my-app-test", service: "minio", id: "abc123")

    daemon.remove_container("abc123")
    daemon.remove_volume("my-app-test_data")

    expect(docker.containers).to be_empty
    expect(docker).to have_run("docker volume rm --force my-app-test_data")
  end
end
