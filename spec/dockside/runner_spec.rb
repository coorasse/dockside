RSpec.describe Dockside::Runner, "running commands" do
  subject(:runner) { described_class.new }

  it "captures stdout, stderr and the exit status" do
    result = runner.run(["sh", "-c", "echo out; echo err >&2; exit 3"])

    expect(result.stdout).to eq("out\n")
    expect(result.stderr).to eq("err\n")
    expect(result.exit_status).to eq(3)
    expect(result).not_to be_success
  end

  it "passes environment variables, stdin and the working directory" do
    result = runner.run(["sh", "-c", "echo $GREETING; cat; pwd"], env: {"GREETING" => "hi"}, stdin: "from stdin\n", chdir: app_root)

    expect(result.stdout).to eq("hi\nfrom stdin\n#{app_root.realpath}\n")
  end

  it "prints the output while the command runs with stream: true, and still returns it" do
    result = runner.run(["sh", "-c", "echo building; echo warning >&2"], stream: true)

    expect(printed).to eq("building\nwarning\n")
    expect(result.stdout).to eq("building\nwarning\n")
    expect(result).to be_success
  end

  it "honours the working directory when streaming" do
    result = runner.run(["pwd"], chdir: app_root, stream: true)

    expect(result.stdout).to eq("#{app_root.realpath}\n")
  end

  describe "#run!" do
    it "returns the result of a successful command" do
      expect(runner.run!(["echo", "ok"]).stdout).to eq("ok\n")
    end

    it "raises CommandFailed with the command and its stderr" do
      expect { runner.run!(["sh", "-c", "echo nope >&2; exit 2"]) }.to raise_error(Dockside::CommandFailed) { |error|
        expect(error.message).to eq("`sh -c echo nope >&2; exit 2` failed with status 2:\nnope")
        expect(error.argv).to eq(["sh", "-c", "echo nope >&2; exit 2"])
        expect(error.stderr).to eq("nope\n")
        expect(error.exit_status).to eq(2)
      }
    end

    it "keeps the message short when the command printed nothing" do
      expect { runner.run!(["false"]) }.to raise_error(Dockside::CommandFailed, "`false` failed with status 1")
    end
  end

  it "explains how to install Docker when the binary is missing" do
    expect { runner.run(["docker-not-installed-anywhere", "version"]) }
      .to raise_error(Dockside::DockerMissing, /docker-not-installed-anywhere was not found.*DOCKSIDE_AUTOSTART=0/m)
  end
end
