require_relative "lib/dockside/version"

Gem::Specification.new do |spec|
  spec.name = "dockside"
  spec.version = Dockside::VERSION
  spec.authors = ["Alessandro Rodi"]
  spec.email = ["alessandro.rodi@renuo.ch"]

  spec.summary = "Starts the Docker containers your Rails app needs, when your app starts."
  spec.description = "Describe the containers your app needs in a compose file. dockside starts them before " \
    "the server and the test suite, waits until they are ready, sets them up the first time and keeps " \
    "development and test apart."
  spec.homepage = "https://github.com/coorasse/dockside"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["funding_uri"] = "https://github.com/sponsors/coorasse"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "zeitwerk", ">= 2.6"
end
