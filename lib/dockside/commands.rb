module Dockside
  # What the rake tasks do, without rake.
  module Commands
    module_function

    def up(names, build: false, pull: false)
      select(names).each { |dependency| dependency.start(build: build, pull: pull) }
    end

    def stop(names)
      select(names).each do |dependency|
        dependency.stop
        Dockside.log "stopped #{dependency.name} (#{dependency.env})"
      end
    end

    def down
      Dockside.down
      Dockside.log "removed the #{Dockside.env} containers"
    end

    def reset(names)
      select(names).each(&:reset)
    end

    def status
      Dockside.registry.each do |dependency|
        Dockside.output.puts status_line(dependency)
      end
    end

    def logs(name, tail: 100, follow: false)
      dependency = Dockside.fetch(name)
      Dockside.project.compose.logs(dependency.name, tail: tail, follow: follow).tap do |result|
        Dockside.output.print result.stdout unless follow
      end
    end

    def config
      Dockside.output.print Dockside.project.resolved_yaml
    end

    def select(names)
      names.empty? ? Dockside.registry.to_a : names.map { |name| Dockside.fetch(name) }
    end

    def status_line(dependency)
      state = if !dependency.running?
        "not running"
      elsif dependency.ready?
        "running, ready"
      else
        "running, not ready"
      end
      state = "#{state}, shared with #{dependency.project.other_env}" if dependency.shared?
      autostart = dependency.autostart? ? "autostart" : "manual"
      [dependency.name, dependency.container_name, state, dependency.url || "no port", autostart].join("  ")
    end
  end
end
