RSpec.describe Dockside::Registry, "the dependencies of the app" do
  before do
    given_the_compose_file <<~YAML, env: "test"
      services:
        minio:
          image: minio/minio
          ports: ["9000:9000"]
          x-dockside:
            test:
              ports: ["9010:9000"]
        keycloak:
          image: keycloak
          ports: ["8080:8080"]
          x-dockside:
            autostart: false
            test:
              ports: ["8081:8080"]
        mailpit:
          image: axllent/mailpit
          ports: ["8025:8025"]
    YAML
  end

  it "lists the services of the compose file" do
    expect(Dockside.names).to eq(%i[minio keycloak mailpit])
  end

  it "gives one dependency per service, for the current environment" do
    expect(Dockside.minio).to be_a(Dockside::Dependency)
    expect(Dockside.minio.port).to eq(9010)
    expect(Dockside.fetch("keycloak").port).to eq(8081)
    expect(Dockside.registry[:mailpit]).to equal(Dockside.mailpit)
  end

  it "does not answer to names that are not services" do
    expect(Dockside).to respond_to(:minio)
    expect(Dockside).not_to respond_to(:postgres)
    expect { Dockside.postgres }.to raise_error(NoMethodError)
    expect { Dockside.minio(1) }.to raise_error(NoMethodError)
  end

  it "names the dependency it does not know" do
    expect { Dockside.fetch(:postgres) }.to raise_error(Dockside::UnknownDependency, "Unknown dependency postgres. Known: minio, keycloak, mailpit.")
  end

  it "knows which dependencies start on their own" do
    expect(Dockside.registry.autostart.map(&:name)).to eq(%w[minio mailpit])
  end

  it "warns about a service that uses the same port in development and test, because it shares its data" do
    expect(Dockside.mailpit).to be_shared
    expect(Dockside.minio).not_to be_shared
    expect(printed).to eq("dockside: warning: mailpit uses port 8025 in development and test, so both environments share one container and its data\n")
  end

  it "does not consider a service without ports shared" do
    given_the_compose_file("services:\n  worker:\n    image: alpine\n")

    expect(Dockside.worker).not_to be_shared
  end
end
