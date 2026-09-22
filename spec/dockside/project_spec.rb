RSpec.describe Dockside::Project, "reading config/dockside.yml" do
  subject(:project) { Dockside.project }

  context "when a service has a test block with its own ports and no volumes" do
    before do
      given_the_compose_file <<~YAML, env: "test"
        services:
          minio:
            image: minio/minio
            ports: ["9000:9000"]
            volumes:
              - ./tmp/dockside/minio:/data
            x-dockside:
              test:
                ports: ["9010:9000"]
                volumes: []
      YAML
    end

    it "writes an override file where the lists of the block replace the lists of the service" do
      project.write_files

      expect(project.override_file.read).to eq(<<~YAML)
        ---
        services:
          minio:
            ports: !override
            - 9010:9000
            volumes: !override []
            extra_hosts:
            - host.docker.internal:host-gateway
      YAML
    end

    it "lets compose resolve the file: the test container publishes only port 9010 and has no volume" do
      minio = project.resolve!.fetch("minio")

      expect(minio["ports"]).to contain_exactly(include("published" => "9010", "target" => 9000))
      expect(minio).not_to have_key("volumes")
    end

    it "keeps the development container on port 9000 with its volume" do
      use_the_app(env: "development")
      minio = project.resolve!.fetch("minio")

      expect(minio["ports"]).to contain_exactly(include("published" => "9000"))
      expect(minio["volumes"]).to contain_exactly(include("type" => "bind", "source" => app_root.join("tmp/dockside/minio").to_s))
    end

    it "gives compose a copy of the file without the x-dockside part, plus the override file" do
      project.write_files

      expect(project.compose.argv_prefix).to eq([
        "docker", "compose", "--project-name", "my-app-test", "--project-directory", app_root.to_s,
        "--file", app_root.join("tmp/dockside/test/dockside.yml").to_s,
        "--file", app_root.join("tmp/dockside/test/override.yml").to_s
      ])
      expect(YAML.safe_load(project.plain_file.read)).to eq(
        "services" => {"minio" => {"image" => "minio/minio", "ports" => ["9000:9000"], "volumes" => ["./tmp/dockside/minio:/data"]}}
      )
    end

    it "knows the host port of each environment without asking compose" do
      expect(project.host_port("minio", "development")).to eq("9000")
      expect(project.host_port("minio", "test")).to eq("9010")
    end
  end

  context "when a service is built from a Dockerfile and has no image name" do
    before do
      given_the_compose_file <<~YAML
        services:
          keycloak:
            build:
              context: .
              dockerfile: Dockerfile.keycloak
            ports: ["8080:8080"]
      YAML
    end

    it "tags the image <app>-<service>, so development and test build it once" do
      expect(project.resolve!.dig("keycloak", "image")).to eq("my-app-keycloak")
    end
  end

  context "when a service already has extra_hosts" do
    before do
      given_the_compose_file <<~YAML
        services:
          web:
            image: nginx
            extra_hosts: ["db.local:10.0.0.1"]
      YAML
    end

    it "adds host.docker.internal next to them" do
      expect(project.resolve!.dig("web", "extra_hosts")).to contain_exactly("db.local=10.0.0.1", "host.docker.internal=host-gateway")
    end
  end

  context "when the file uses ${RAILS_ENV}" do
    before do
      given_the_compose_file <<~YAML, env: "test"
        services:
          redmine:
            image: redmine
            volumes:
              - ./tmp/dockside/${RAILS_ENV}/redmine:/files
      YAML
    end

    it "interpolates the current environment" do
      source = project.resolve!.dig("redmine", "volumes", 0, "source")

      expect(source).to eq(app_root.join("tmp/dockside/test/redmine").to_s)
    end
  end

  context "when config/dockside.test.yml exists next to the main file" do
    before do
      given_the_compose_file <<~YAML, env: "test"
        services:
          web:
            image: nginx
            environment:
              A: "1"
      YAML
      app_root.join("config/dockside.test.yml").write(<<~YAML)
        services:
          web:
            environment:
              B: "2"
      YAML
    end

    it "applies it as a compose override file" do
      expect(project.files.map(&:basename).map(&:to_s)).to eq(["dockside.yml", "dockside.test.yml", "override.yml"])
      expect(project.files.first).to eq(project.plain_file)
      expect(project.resolve!.dig("web", "environment")).to eq("A" => "1", "B" => "2")
    end

    it "ignores it in the other environment" do
      use_the_app(env: "development")

      expect(project.files.map(&:basename).map(&:to_s)).to eq(["dockside.yml", "override.yml"])
    end
  end

  context "when the compose file uses YAML anchors" do
    before do
      given_the_compose_file <<~YAML
        x-common: &common
          image: nginx
        services:
          one:
            <<: *common
          two:
            <<: *common
      YAML
    end

    it "reads them like compose does" do
      expect(project.service_names).to eq(%w[one two])
      expect(project.resolve!.dig("two", "image")).to eq("nginx")
    end
  end

  context "when a service sets container_name" do
    before do
      given_the_compose_file <<~YAML
        services:
          minio:
            image: minio/minio
            container_name: my-minio
      YAML
    end

    it "refuses the file, because dockside names the containers itself" do
      expect { project.service_names }.to raise_error(Dockside::ConfigError, /container_name.*my-app-<environment>-minio-1/)
    end
  end

  context "when x-dockside has a key the gem does not know" do
    before do
      given_the_compose_file <<~YAML
        services:
          minio:
            image: minio/minio
            x-dockside:
              after_stat: []
      YAML
    end

    it "refuses the file and lists the allowed keys" do
      expect { project.service_names }
        .to raise_error(Dockside::ConfigError, "Unknown x-dockside key after_stat for service minio. " \
          "Allowed: ready, timeout, after_start, autostart, development, test.")
    end
  end

  context "when the compose file does not exist" do
    before { use_the_app }

    it "tells how to create it" do
      expect { project.service_names }.to raise_error(Dockside::ConfigError, /does not exist.*generate dockside:install/)
    end
  end

  context "when the compose file has no services" do
    before { given_the_compose_file("") }

    it "has no service" do
      expect(project.service_names).to be_empty
    end
  end

  describe "the settings of a service in one environment" do
    before do
      given_the_compose_file <<~YAML, env: "test"
        services:
          minio:
            image: minio/minio
            x-dockside:
              ready: none
              timeout: 60
              autostart: false
              after_start:
                - exec: mc mb local/uploads
              test:
                timeout: 10
                ports: ["9010:9000"]
      YAML
    end

    it "merges the keys of the environment block over the shared ones and keeps the defaults for the rest" do
      settings = project.settings("minio")

      expect(settings.ready).to eq("none")
      expect(settings.timeout).to eq(10)
      expect(settings.autostart?).to be(false)
      expect(settings.after_start.map(&:exec)).to eq(["mc mb local/uploads"])
    end

    it "uses the defaults when nothing is configured" do
      given_the_compose_file("services:\n  web:\n    image: nginx\n")
      settings = project.settings("web")

      expect(settings.ready).to eq("auto")
      expect(settings.timeout).to eq(300)
      expect(settings.autostart?).to be(true)
      expect(settings.after_start).to be_empty
    end
  end
end
