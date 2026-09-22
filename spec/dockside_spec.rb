RSpec.describe Dockside, "the module API" do
  before do
    given_the_compose_file <<~YAML, env: "test"
      services:
        minio:
          image: minio/minio
          x-dockside:
            ready: none
        keycloak:
          image: keycloak
          x-dockside:
            ready: none
            autostart: false
        mailpit:
          image: axllent/mailpit
          x-dockside:
            ready: none
    YAML
  end

  describe ".ensure_running!" do
    it "starts every dependency with autostart when called without names" do
      described_class.ensure_running!

      expect(described_class.minio).to be_running
      expect(described_class.mailpit).to be_running
      expect(described_class.keycloak).not_to be_running
    end

    it "starts the named dependencies, also the ones without autostart" do
      described_class.ensure_running!(:keycloak)

      expect(described_class.keycloak).to be_running
      expect(described_class.minio).not_to be_running
    end

    it "does nothing the second time" do
      described_class.ensure_running!
      docker.calls.clear

      described_class.ensure_running!

      expect(docker).not_to have_run("compose", "up")
    end
  end

  describe ".down" do
    it "removes the containers of the current environment and keeps the volumes" do
      described_class.ensure_running!

      described_class.down

      expect(docker).to have_run("docker compose --project-name my-app-test", "down")
      expect(docker.containers).to be_empty
      expect(docker).not_to have_run("volume rm")
    end

    it "also removes a shared container that the other environment created" do
      given_the_compose_file <<~YAML, env: "test"
        services:
          mailpit:
            image: axllent/mailpit
            ports: ["8025:8025"]
      YAML
      the_container_is_running(:mailpit, env: "development")

      described_class.down

      expect(docker.containers).to be_empty
    end
  end

  describe ".log" do
    it "prefixes every line with the gem name" do
      described_class.log "hello"

      expect(printed).to eq("dockside: hello\n")
    end
  end

  describe "the defaults without Rails" do
    it "derives the app name from the folder and the environment from RAILS_ENV" do
      described_class.reset!
      described_class.root = app_root
      hide_const("Rails")

      expect(described_class.app_name).to eq(app_root.basename.to_s)
      expect(described_class.env).to eq(ENV.fetch("RAILS_ENV", "development"))
      expect(described_class.runner).to be_a(Dockside::Runner)
      expect(described_class.output).to be_a(StringIO)
    end

    it "uses the current folder as root" do
      described_class.reset!
      hide_const("Rails")

      expect(described_class.root).to eq(Pathname.new(Dir.pwd))
    end
  end
end
