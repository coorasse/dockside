require "rails_helper"
require "ammeter/init"
require "generators/dockside/install_generator"

RSpec.describe Dockside::Generators::InstallGenerator, type: :generator do
  destination File.expand_path("../tmp/generator", __dir__)

  before { prepare_destination }

  after { FileUtils.rm_rf(destination_root) }

  it "creates config/dockside.yml with a commented example" do
    run_generator

    config = file("config/dockside.yml")
    expect(config).to exist
    expect(config).to contain("services:")
    expect(config).to contain("#   x-dockside:")
  end

  it "creates a file that compose and the gem can read" do
    run_generator

    yaml = YAML.safe_load_file(file("config/dockside.yml"))
    expect(yaml).to eq("services" => {})
  end
end
