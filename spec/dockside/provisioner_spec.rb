RSpec.describe Dockside::Provisioner, "running after_start steps" do
  let(:port) { a_free_port }

  def dependency_with_steps(steps)
    given_the_compose_file <<~YAML, env: "test"
      services:
        redmine:
          image: redmine
          ports: ["3000:3000"]
          x-dockside:
            test:
              ports: ["#{port}:3000"]
            after_start:
      #{steps.lines.map { |line| "        #{line}" }.join}
    YAML
    the_container_is_running(:redmine)
    Dockside.redmine
  end

  def provision(dependency)
    dependency.provisioner.run(the_container_of(:redmine).id)
  end

  describe "exec: steps" do
    it "runs the command inside the container with the dockside variables and prints what it does" do
      redmine = dependency_with_steps("- exec: bundle exec rake redmine:load_default_data\n")

      provision(redmine)

      expect(docker).to have_run("exec --no-TTY --env DOCKSIDE_NAME=redmine --env DOCKSIDE_ENV=test " \
        "--env DOCKSIDE_PORT=#{port} --env DOCKSIDE_URL=http://localhost:#{port} --env DOCKSIDE_CONTAINER=my-app-test-redmine-1 " \
        "redmine sh -c bundle exec rake redmine:load_default_data")
      expect(printed).to eq("dockside: redmine: exec bundle exec rake redmine:load_default_data\n")
    end

    it "passes environment, workdir, user and a file as stdin" do
      app_root.join("bin").mkpath
      app_root.join("bin/setup_redmine.rb").write("puts 'hello'")
      redmine = dependency_with_steps(<<~YAML)
        - exec: bundle exec rails runner -
          environment: { REDMINE_LANG: en }
          workdir: /usr/src/redmine
          user: redmine
          stdin: bin/setup_redmine.rb
      YAML

      provision(redmine)

      call = docker.runs_of("exec").last
      expect(call.to_s).to include("--env REDMINE_LANG=en --workdir /usr/src/redmine --user redmine redmine sh -c bundle exec rails runner -")
      expect(call.stdin).to eq("puts 'hello'")
    end

    it "stops at the first failing step" do
      redmine = dependency_with_steps("- exec: first\n- exec: second\n")
      docker.on("exec", "first", stderr: "boom", exit_status: 1)

      expect { provision(redmine) }.to raise_error(Dockside::CommandFailed, /boom/)
      expect(docker).not_to have_run("exec", "second")
      expect(redmine.provisioner.marker).not_to exist
    end

    it "moves on when a step with allow_failure: true fails, and says why it failed" do
      redmine = dependency_with_steps("- exec: first\n  allow_failure: true\n- exec: second\n")
      docker.on("exec", "first", stderr: "Some configuration data is already loaded.\n", exit_status: 1)

      provision(redmine)

      expect(docker).to have_run("exec", "second")
      expect(printed).to include("dockside: redmine: the step failed, moving on because of allow_failure:\n" \
        "Some configuration data is already loaded.\n")
    end
  end

  describe "run: steps" do
    it "runs the command on the host, in the app folder, with the dockside variables" do
      redmine = dependency_with_steps("- run: [sh, -c, 'pwd > seen; echo $DOCKSIDE_URL >> seen']\n")

      provision(redmine)

      expect(app_root.join("seen").read).to eq("#{app_root.realpath}\nhttp://localhost:#{port}\n")
    end

    it "accepts a string and runs it through the shell" do
      redmine = dependency_with_steps("- run: echo $DOCKSIDE_PORT > port\n")

      provision(redmine)

      expect(app_root.join("port").read).to eq("#{port}\n")
    end

    it "raises when the command fails, unless allow_failure is set" do
      expect { provision(dependency_with_steps("- run: exit 3\n")) }.to raise_error(Dockside::CommandFailed, /exit 3.*status 3/)
      expect { provision(dependency_with_steps("- run: exit 3\n  allow_failure: true\n")) }.not_to raise_error
    end
  end

  describe "running once per container" do
    it "remembers the container it provisioned and skips it next time" do
      redmine = dependency_with_steps("- exec: seed\n")

      provision(redmine)
      provision(redmine)

      expect(docker.runs_of("exec", "seed").size).to eq(1)
      expect(redmine.provisioner.marker.read).to eq(the_container_of(:redmine).id)
    end

    it "runs again for another container" do
      redmine = dependency_with_steps("- exec: seed\n")
      provision(redmine)

      the_container_is_recreated(:redmine)
      provision(redmine)

      expect(docker.runs_of("exec", "seed").size).to eq(2)
    end

    it "runs steps with always: true on every start" do
      redmine = dependency_with_steps("- exec: seed\n- exec: refresh\n  always: true\n")

      provision(redmine)
      provision(redmine)

      expect(docker.runs_of("exec", "seed").size).to eq(1)
      expect(docker.runs_of("exec", "refresh").size).to eq(2)
    end
  end

  describe "an invalid step" do
    it "is refused when it has neither exec nor run" do
      expect { dependency_with_steps("- stdin: file\n") }
        .to raise_error(Dockside::ConfigError, /redmine: every after_start step needs exec: or run:/)
    end

    it "is refused when it has both" do
      expect { dependency_with_steps("- exec: a\n  run: b\n") }.to raise_error(Dockside::ConfigError)
    end

    it "is refused when it has an unknown option" do
      expect { dependency_with_steps("- exec: a\n  retries: 3\n") }.to raise_error(Dockside::ConfigError, /retries/)
    end

    it "is refused when it is not a hash" do
      expect { dependency_with_steps("- mc mb local/uploads\n") }.to raise_error(Dockside::ConfigError)
    end
  end
end
