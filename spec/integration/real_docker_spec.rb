# Runs against the real Docker daemon. Enabled with DOCKER=1.
RSpec.describe "dockside with a real Docker", :docker do
  # Fixed ports outside the ephemeral range, so nothing grabs them between the check and compose up.
  let(:web_port) { 18080 }
  let(:echo_port) { 18081 }

  # A new process would build the registry again; this does the same in the running one.
  def start_over
    Dockside.reset!
    Dockside.root = app_root
    Dockside.env = "test"
    Dockside.app_name = "dockside-integration"
  end

  before do
    WebMock.allow_net_connect!
    Dockside.output = $stdout
    Dockside.poll_interval = 0.2
    given_the_compose_file <<~YAML, env: "test", app_name: "dockside-integration"
      services:
        web:
          image: nginx:alpine
          ports: ["80:80"]
          volumes:
            - ./tmp/dockside/${RAILS_ENV}/web:/usr/share/nginx/html
          x-dockside:
            ready: { http: "/" }
            timeout: 60
            after_start:
              - exec: sh -c 'echo "hello from $DOCKSIDE_NAME" > /usr/share/nginx/html/index.html'
              - run: sh -c 'echo provisioned > tmp/dockside/test/provisioned'
            test:
              ports: ["#{web_port}:80"]
        echo:
          image: hashicorp/http-echo
          command: ["-listen=:5678", "-text=hi"]
          ports: ["5678:5678"]
          x-dockside:
            timeout: 60
            test:
              ports: ["#{echo_port}:5678"]
    YAML
    start_over
  end

  after do
    start_over
    Dockside.down
    WebMock.disable_net_connect!
  end

  it "starts the containers, waits until they answer, provisions them once and resets them" do
    Dockside.ensure_running!

    expect(Dockside.web).to be_ready
    expect(Dockside.echo).to be_ready
    expect(Net::HTTP.get(URI("http://localhost:#{web_port}/"))).to eq("hello from web\n")
    expect(app_root.join("tmp/dockside/test/provisioned").read).to eq("provisioned\n")
    expect(app_root.join("tmp/dockside/test/web/index.html").read).to eq("hello from web\n")

    start_over
    Dockside.ensure_running!
    expect(Dockside.web.logs(tail: 5)).not_to be_empty

    expect(Dockside.web.exec("cat /usr/share/nginx/html/index.html")).to eq("hello from web\n")
    expect(Dockside.web.exec("cat", stdin: "from stdin")).to eq("from stdin")
    expect { Dockside.web.exec("false") }.to raise_error(Dockside::CommandFailed)

    Dockside.web.stop
    expect(Dockside.web).not_to be_running

    Dockside.web.reset
    expect(Dockside.web).to be_ready
    expect(app_root.join("tmp/dockside/test/web/index.html").read).to eq("hello from web\n")
  end
end
