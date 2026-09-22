require "socket"
require "tmpdir"

# The vocabulary the specs are written in: an app with a compose file, a fake docker, listening ports.
module World
  def docker
    @docker ||= FakeDocker.new
  end

  def app_root
    @app_root ||= Pathname.new(Dir.mktmpdir("dockside-app"))
  end

  # The app has this config/dockside.yml and dockside works for the given environment.
  def given_the_compose_file(yaml, env: "test", app_name: "my-app")
    app_root.join("config").mkpath
    app_root.join("config/dockside.yml").write(yaml)
    use_the_app(env: env, app_name: app_name)
  end

  def use_the_app(env: "test", app_name: "my-app")
    Dockside.reset!
    Dockside.root = app_root
    Dockside.env = env
    Dockside.app_name = app_name
    Dockside.runner = docker
  end

  def the_container_is_running(service, env: Dockside.env, state: "running")
    docker.add_container(project: "my-app-#{env}", service: service.to_s, state: state)
  end

  # A container dockside itself started earlier, so it also remembers the compose config it used.
  def the_container_was_started_by_dockside(service)
    the_container_is_running(service)
    Dockside.fetch(service).send(:remember_config)
  end

  def the_container_is_recreated(service, env: Dockside.env)
    docker.add_container(project: "my-app-#{env}", service: service.to_s, recreate: true)
  end

  def the_container_of(service, env: Dockside.env)
    docker.container_of(project: "my-app-#{env}", service: service.to_s)
  end

  def the_container_log_says(service, text, env: Dockside.env)
    docker.logs_of(project: "my-app-#{env}", service: service.to_s, text: text)
  end

  def a_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1].tap { server.close }
  end

  # Accepts connections on the port and keeps them open, like a web server waiting for a request.
  # With a block, every connection is handed to the block instead.
  def a_server_listening_on(port, &handler)
    server = TCPServer.new("127.0.0.1", port)
    listening_servers << server
    return server unless handler

    listening_threads << Thread.new do
      loop { handler.call(server.accept) }
    rescue IOError
      nil
    end
    server
  end

  def listening_servers
    @listening_servers ||= []
  end

  def listening_threads
    @listening_threads ||= []
  end

  def close_listening_servers
    listening_servers.each(&:close)
    listening_threads.each { |thread| thread.join(1) }
  end

  def printed
    Dockside.output.string
  end

  def work_dir
    app_root.join("tmp/dockside", Dockside.env)
  end
end
