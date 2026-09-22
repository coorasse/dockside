require "rails_helper"

RSpec.describe "the dockside rake tasks" do
  let(:port) { a_free_port }

  before do
    given_the_compose_file <<~YAML, env: "test"
      services:
        minio:
          image: minio/minio
          ports: ["9000:9000"]
          volumes:
            - ./tmp/dockside/${RAILS_ENV}/minio:/data
          x-dockside:
            ready: none
            test:
              ports: ["#{port}:9000"]
        keycloak:
          image: keycloak
          ports: ["8080:8080"]
          x-dockside:
            ready: none
            autostart: false
            test:
              ports: ["8081:8080"]
    YAML
    load_the_rake_tasks
  end

  def run_task(name, *args, env: {})
    stub_const("ENV", ENV.to_h.merge(env))
    Rake::Task[name].reenable
    Rake::Task[name].invoke(*args)
  end

  describe "dockside:up" do
    it "starts every container without arguments" do
      run_task("dockside:up")

      expect(Dockside.minio).to be_running
      expect(Dockside.keycloak).to be_running
    end

    it "starts the named containers, separated by commas" do
      run_task("dockside:up", "keycloak")

      expect(Dockside.keycloak).to be_running
      expect(Dockside.minio).not_to be_running
    end

    it "takes more than one name" do
      run_task("dockside:up", "minio", "keycloak")

      expect(docker.runs_of("up").size).to eq(2)
    end

    it "rebuilds with BUILD=1 and pulls with PULL=1" do
      run_task("dockside:up", "minio", env: {"BUILD" => "1", "PULL" => "1"})

      expect(docker).to have_run("up --detach --wait --wait-timeout 300 --build --pull always minio")
    end
  end

  describe "dockside:stop" do
    it "stops the containers and keeps them" do
      the_container_is_running(:minio)

      run_task("dockside:stop", "minio")

      expect(the_container_of(:minio).state).to eq("exited")
      expect(printed).to include("dockside: stopped minio (test)")
    end
  end

  describe "dockside:down" do
    it "removes the containers of the environment" do
      the_container_is_running(:minio)

      run_task("dockside:down")

      expect(docker.containers).to be_empty
      expect(printed).to include("dockside: removed the test containers")
    end
  end

  describe "dockside:reset" do
    it "removes the containers with their data and starts them again" do
      the_container_is_running(:minio)
      before = the_container_of(:minio).id

      run_task("dockside:reset", "minio")

      expect(docker).to have_run("rm --stop --force --volumes minio")
      expect(the_container_of(:minio).id).not_to eq(before)
      expect(Dockside.minio).to be_running
    end
  end

  describe "dockside:status" do
    it "shows every container, its state, url and whether it starts on its own" do
      the_container_is_running(:minio)

      run_task("dockside:status")

      expect(printed).to eq(<<~TEXT)
        minio  my-app-test-minio-1  running, ready  http://localhost:#{port}  autostart
        keycloak  my-app-test-keycloak-1  not running  http://localhost:8081  manual
      TEXT
    end

    it "tells when a running container does not answer yet and when it is shared with the other environment" do
      given_the_compose_file <<~YAML, env: "test"
        services:
          mailpit:
            image: axllent/mailpit
            ports: ["#{port}:8025"]
          worker:
            image: alpine
      YAML
      the_container_is_running(:mailpit)

      run_task("dockside:status")

      expect(printed).to include("mailpit  my-app-test-mailpit-1  running, not ready, shared with development  http://localhost:#{port}  autostart")
      expect(printed).to include("worker  my-app-test-worker-1  not running  no port  autostart")
    end
  end

  describe "dockside:logs" do
    before { the_container_log_says(:minio, "API: http://0.0.0.0:9000\n") }

    it "prints the last 100 lines of the container log" do
      run_task("dockside:logs", "minio")

      expect(docker).to have_run("logs --no-color --tail 100 minio")
      expect(printed).to eq("API: http://0.0.0.0:9000\n")
    end

    it "takes TAIL and FOLLOW" do
      run_task("dockside:logs", "minio", env: {"TAIL" => "20", "FOLLOW" => "1"})

      expect(docker).to have_run("logs --no-color --tail 20 --follow minio")
      expect(printed).to eq("")
    end
  end

  describe "dockside:config" do
    it "prints the compose file the gem really uses, without the x-dockside part" do
      run_task("dockside:config")

      resolved = YAML.safe_load(printed)
      expect(resolved["name"]).to eq("my-app-test")
      expect(resolved.dig("services", "minio", "ports", 0, "published")).to eq(port.to_s)
      expect(resolved.dig("services", "minio", "extra_hosts")).to eq(["host.docker.internal=host-gateway"])
      expect(printed).not_to include("x-dockside")
    end
  end
end
