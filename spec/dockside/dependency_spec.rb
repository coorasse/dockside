RSpec.describe Dockside::Dependency do
  let(:port) { a_free_port }

  # minio on port 9000 in development and on a free port in test, with the given extra lines
  # in the service and in its x-dockside block.
  def compose_file_for_minio(service: "", x_dockside: "")
    <<~YAML
      services:
        minio:
          image: minio/minio
          ports: ["9000:9000"]
          volumes:
            - ./tmp/dockside/${RAILS_ENV}/minio:/data
      #{indent(service, 4)}
          x-dockside:
            test:
              ports: ["#{port}:9000"]
      #{indent(x_dockside, 6)}
    YAML
  end

  def indent(text, spaces)
    text.lines.map { |line| "#{" " * spaces}#{line}" }.join.chomp
  end

  describe "#start" do
    context "when the container does not exist yet" do
      before do
        given_the_compose_file compose_file_for_minio, env: "test"
        docker.after_starting(:minio) { a_server_listening_on(port) }
      end

      it "brings it up with compose and waits until the port answers" do
        Dockside.minio.start

        expect(docker).to have_run("docker compose --project-name my-app-test", "up --detach --wait --wait-timeout 300 minio")
        expect(printed).to eq("dockside: starting minio (test)\ndockside: minio ready at http://localhost:#{port}\n")
      end

      it "creates the folders of the bind mounts before compose needs them, writable for any user" do
        Dockside.minio.start

        data = app_root.join("tmp/dockside/test/minio")
        expect(data).to be_directory
        expect(data.stat.mode & 0o777).to eq(0o777)
      end

      it "runs `docker version` and `docker compose version` first, so a missing Docker fails fast" do
        Dockside.minio.start

        commands = docker.calls.map(&:to_s).grep_v(/ config/)
        expect(commands.first(2)).to eq(["docker version --format {{.Server.Version}}", "docker compose version"])
      end

      it "rebuilds the image with build: true and pulls it with pull: true" do
        Dockside.minio.start(build: true, pull: true)

        expect(docker).to have_run("up --detach --wait --wait-timeout 300 --build --pull always minio")
      end
    end

    context "when the container is already running and answers on its port" do
      before do
        given_the_compose_file compose_file_for_minio, env: "test"
        the_container_was_started_by_dockside(:minio)
        a_server_listening_on(port)
      end

      it "does not call compose at all" do
        Dockside.minio.start

        expect(docker).not_to have_run("compose", "up")
        expect(printed).to eq("dockside: minio already running at http://localhost:#{port}\n")
      end

      it "still calls compose when asked to build or pull" do
        Dockside.minio.start(build: true)

        expect(docker).to have_run("up", "--build", "minio")
      end
    end

    context "when the container is running but the compose file changed since it was started" do
      before do
        given_the_compose_file compose_file_for_minio, env: "test"
        the_container_was_started_by_dockside(:minio)
        a_server_listening_on(port)
        given_the_compose_file compose_file_for_minio(service: "environment:\n  NEW: value\n"), env: "test"
      end

      it "lets compose recreate it" do
        Dockside.minio.start

        expect(docker).to have_run("up", "minio")
      end
    end

    context "when the container exists but is stopped" do
      before do
        given_the_compose_file compose_file_for_minio, env: "test"
        the_container_is_running(:minio, state: "exited")
        docker.after_starting(:minio) { a_server_listening_on(port) }
      end

      it "starts it again" do
        Dockside.minio.start

        expect(docker).to have_run("up", "minio")
        expect(Dockside.minio).to be_running
      end
    end

    context "when the service is shared between development and test and development already runs it" do
      before do
        given_the_compose_file <<~YAML, env: "test"
          services:
            mailpit:
              image: axllent/mailpit
              ports: ["#{port}:8025"]
        YAML
        the_container_is_running(:mailpit, env: "development")
        a_server_listening_on(port)
      end

      it "uses the development container instead of starting a second one" do
        Dockside.mailpit.start

        expect(docker).not_to have_run("compose", "up")
        expect(printed).to include("dockside: mailpit shared with development at http://localhost:#{port}\n")
      end

      it "starts its own container when the development one does not answer" do
        close_listening_servers
        docker.after_starting(:mailpit) { a_server_listening_on(port) }

        Dockside.mailpit.start

        expect(docker).to have_run("compose", "up", "mailpit")
      end
    end

    context "when compose fails to start the container" do
      before do
        given_the_compose_file compose_file_for_minio, env: "test"
        the_container_log_says(:minio, "ERROR: cannot open /data\n")
      end

      it "raises with the compose output and the last log lines" do
        docker.on("compose", "up", stdout: "Error response from daemon: OCI runtime create failed", exit_status: 1)

        expect { Dockside.minio.start }.to raise_error(Dockside::CommandFailed) { |error|
          expect(error.message).to include("minio (test) failed to start:")
          expect(error.message).to include("OCI runtime create failed")
          expect(error.message).to include("Last 50 log lines:\nERROR: cannot open /data")
          expect(error.exit_status).to eq(1)
        }
      end

      it "explains when another process holds the port" do
        docker.on("compose", "up", stdout: "Bind for 0.0.0.0:#{port} failed: port is already allocated", exit_status: 1)

        expect { Dockside.minio.start }.to raise_error(Dockside::PortInUse, /port #{port} is in use.*docker ps/m)
      end
    end

    context "when the container runs but never answers on its port" do
      before do
        given_the_compose_file compose_file_for_minio(x_dockside: "timeout: 0\n"), env: "test"
        the_container_log_says(:minio, "still booting\n")
      end

      it "gives up after the timeout and shows the log" do
        expect { Dockside.minio.start }.to raise_error(Dockside::ReadyTimeout, <<~MESSAGE.strip)
          minio (test) did not become ready within 0s (waited until port #{port} accepts connections). Last 50 log lines:
          still booting
        MESSAGE
      end
    end

    context "when the service has after_start steps" do
      before do
        given_the_compose_file compose_file_for_minio(x_dockside: <<~YAML), env: "test"
          ready: none
          after_start:
            - exec: mc mb local/uploads
        YAML
      end

      it "runs them once the container is ready and remembers that for this container" do
        Dockside.minio.start

        expect(docker.calls.map(&:to_s).grep(/ up | exec /)).to eq([
          "docker compose --project-name my-app-test --project-directory #{app_root} --file #{app_root}/tmp/dockside/test/dockside.yml --file #{app_root}/tmp/dockside/test/override.yml up --detach --wait --wait-timeout 300 minio",
          "docker compose --project-name my-app-test --project-directory #{app_root} --file #{app_root}/tmp/dockside/test/dockside.yml --file #{app_root}/tmp/dockside/test/override.yml exec --no-TTY --env DOCKSIDE_NAME=minio --env DOCKSIDE_ENV=test --env DOCKSIDE_PORT=#{port} --env DOCKSIDE_URL=http://localhost:#{port} --env DOCKSIDE_CONTAINER=my-app-test-minio-1 minio sh -c mc mb local/uploads"
        ])
        expect(work_dir.join("minio.provisioned").read).to eq(the_container_of(:minio).id)
      end

      it "does not run them again when the same container is started again" do
        Dockside.minio.start
        Dockside.minio.stop
        Dockside.minio.start

        expect(docker.runs_of("exec").size).to eq(1)
      end

      it "runs them again for a new container" do
        Dockside.minio.start
        Dockside.minio.reset

        expect(docker.runs_of("exec").size).to eq(2)
      end
    end

    context "when two processes start the same dependency at the same time" do
      before do
        given_the_compose_file compose_file_for_minio(x_dockside: "ready: none\n"), env: "test"
      end

      it "serializes them with a lock file in tmp/dockside" do
        lock = work_dir.join(".lock")
        started = Queue.new
        holder = Thread.new do
          work_dir.mkpath
          File.open(lock, File::RDWR | File::CREAT) do |file|
            file.flock(File::LOCK_EX)
            started << true
            sleep 0.2
          end
        end
        started.pop
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Dockside.minio.start
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        holder.join

        expect(elapsed).to be > 0.15
      end
    end
  end

  describe "the checks before the first start" do
    before { given_the_compose_file compose_file_for_minio, env: "test" }

    it "fails with DockerMissing when docker is not installed" do
      docker.not_installed!

      expect { Dockside.minio.start }.to raise_error(Dockside::DockerMissing)
    end

    it "fails with DockerUnavailable when the daemon does not answer" do
      docker.daemon_down!

      expect { Dockside.minio.start }.to raise_error(Dockside::DockerUnavailable, /daemon does not answer.*DOCKSIDE_AUTOSTART=0/m)
    end

    it "fails with ComposeMissing when the compose plugin is missing" do
      docker.compose_missing!

      expect { Dockside.minio.start }.to raise_error(Dockside::ComposeMissing, /compose plugin is missing/)
    end
  end

  describe "#running? and #ready?" do
    before { given_the_compose_file compose_file_for_minio, env: "test" }

    it "is not running without a container" do
      expect(Dockside.minio).not_to be_running
      expect(Dockside.minio).not_to be_ready
    end

    it "is running but not ready while the port does not answer" do
      the_container_is_running(:minio)

      expect(Dockside.minio).to be_running
      expect(Dockside.minio).not_to be_ready
    end

    it "is ready once the port answers" do
      the_container_is_running(:minio)
      a_server_listening_on(port)

      expect(Dockside.minio).to be_ready
    end

    it "is not running when the container exited" do
      the_container_is_running(:minio, state: "exited")

      expect(Dockside.minio).not_to be_running
    end
  end

  describe "#stop" do
    before do
      given_the_compose_file compose_file_for_minio, env: "test"
      the_container_is_running(:minio)
    end

    it "stops the container and keeps it" do
      Dockside.minio.stop

      expect(docker).to have_run("compose --project-name my-app-test", "stop minio")
      expect(the_container_of(:minio).state).to eq("exited")
    end
  end

  describe "#reset" do
    before do
      given_the_compose_file <<~YAML, env: "test"
        services:
          minio:
            image: minio/minio
            ports: ["#{port}:9000"]
            volumes:
              - ./tmp/dockside/${RAILS_ENV}/minio:/data
              - ./config/minio:/config
              - minio-cache:/cache
            x-dockside:
              ready: none
        volumes:
          minio-cache:
      YAML
      the_container_is_running(:minio)
      work_dir.mkpath
      work_dir.join("minio.provisioned").write("old")
      app_root.join("tmp/dockside/test/minio/some.file").tap { |file| file.dirname.mkpath }.write("data")
      app_root.join("config/minio/settings").tap { |file| file.dirname.mkpath }.write("keep me")
    end

    it "removes the container, its named volumes and the data in its folders under tmp/, then starts again" do
      Dockside.minio.reset

      expect(docker).to have_run("rm --stop --force --volumes minio")
      expect(docker).to have_run("docker volume rm --force my-app-test_minio-cache")
      expect(app_root.join("tmp/dockside/test/minio/some.file")).not_to exist
      expect(app_root.join("tmp/dockside/test/minio")).to be_directory
      expect(docker).to have_run("up", "minio")
      expect(Dockside.minio).to be_running
    end

    it "never deletes a bind mount outside tmp/" do
      Dockside.minio.reset

      expect(app_root.join("config/minio/settings").read).to eq("keep me")
    end

    it "forgets that the old container was provisioned" do
      Dockside.minio.reset

      expect(work_dir.join("minio.provisioned").read).to eq(the_container_of(:minio).id)
    end

    it "also removes the container of the other environment when the service is shared" do
      given_the_compose_file <<~YAML, env: "test"
        services:
          mailpit:
            image: axllent/mailpit
            ports: ["#{port}:8025"]
            x-dockside:
              ready: none
      YAML
      the_container_is_running(:mailpit, env: "development", state: "exited")

      Dockside.mailpit.reset

      expect(the_container_of(:mailpit, env: "development")).to be_nil
      expect(the_container_of(:mailpit, env: "test")).to be_running
    end
  end

  describe "#exec" do
    before do
      given_the_compose_file compose_file_for_minio, env: "test"
      the_container_is_running(:minio)
    end

    it "runs the command inside the container and returns its output" do
      docker.on("exec", "mc ls local/uploads", stdout: "photo.png\n")

      expect(Dockside.minio.exec("mc ls local/uploads")).to eq("photo.png\n")
      expect(docker).to have_run("exec --no-TTY minio sh -c mc ls local/uploads")
    end

    it "takes an argv array, environment, stdin, workdir and user" do
      Dockside.minio.exec(["mc", "mb", "local/uploads"], environment: {"MC_HOST" => "local"}, stdin: "input", workdir: "/data", user: "minio")

      call = docker.runs_of("exec").last
      expect(call.to_s).to end_with("exec --no-TTY --env MC_HOST=local --workdir /data --user minio minio mc mb local/uploads")
      expect(call.stdin).to eq("input")
    end

    it "raises when the command fails" do
      docker.on("exec", "mc rm", stderr: "mc: <ERROR> Unable to remove", exit_status: 1)

      expect { Dockside.minio.exec("mc rm local/uploads") }.to raise_error(Dockside::CommandFailed, /Unable to remove/) { |error|
        expect(error.stderr).to eq("mc: <ERROR> Unable to remove")
      }
    end

    it "moves on with allow_failure: true" do
      docker.on("exec", "mc rm", stdout: "partial", exit_status: 1)

      expect(Dockside.minio.exec("mc rm local/uploads", allow_failure: true)).to eq("partial")
    end
  end

  describe "#logs" do
    before do
      given_the_compose_file compose_file_for_minio, env: "test"
      the_container_log_says(:minio, "API: http://0.0.0.0:9000\n")
    end

    it "returns the last lines of the container log" do
      expect(Dockside.minio.logs(tail: 20)).to eq("API: http://0.0.0.0:9000\n")
      expect(docker).to have_run("logs --no-color --tail 20 minio")
    end
  end

  describe "what a dependency knows about itself" do
    before do
      given_the_compose_file <<~YAML, env: "test"
        services:
          minio:
            image: minio/minio
            ports: ["9000:9000"]
            x-dockside:
              test:
                ports: ["9010:9000"]
          worker:
            image: alpine
      YAML
    end

    it "has a port, a url and a container name" do
      minio = Dockside.minio

      expect(minio.name).to eq("minio")
      expect(minio.env).to eq("test")
      expect(minio.port).to eq(9010)
      expect(minio.container_port).to eq(9000)
      expect(minio.url).to eq("http://localhost:9010")
      expect(minio.container_name).to eq("my-app-test-minio-1")
      expect(minio).to be_autostart
    end

    it "has no port and no url without published ports" do
      expect(Dockside.worker.port).to be_nil
      expect(Dockside.worker.url).to be_nil
    end
  end
end
