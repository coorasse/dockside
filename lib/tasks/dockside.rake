namespace :dockside do
  names = ->(args) { [args[:names], *args.extras].compact.map(&:strip) }

  desc "Start the containers (BUILD=1 rebuilds, PULL=1 pulls). Names separated by commas."
  task :up, [:names] => :environment do |_task, args|
    Dockside::Commands.up(names.call(args), build: ENV["BUILD"] == "1", pull: ENV["PULL"] == "1")
  end

  desc "Stop the containers, keep the data"
  task :stop, [:names] => :environment do |_task, args|
    Dockside::Commands.stop(names.call(args))
  end

  desc "Remove the containers, keep the data"
  task down: :environment do
    Dockside::Commands.down
  end

  desc "Remove the containers and the data, start again"
  task :reset, [:names] => :environment do |_task, args|
    Dockside::Commands.reset(names.call(args))
  end

  desc "Show every container, its state and URL"
  task status: :environment do
    Dockside::Commands.status
  end

  desc "Show the container log (TAIL=200, FOLLOW=1)"
  task :logs, [:name] => :environment do |_task, args|
    Dockside::Commands.logs(args.fetch(:name), tail: ENV.fetch("TAIL", 100).to_i, follow: ENV["FOLLOW"] == "1")
  end

  desc "Show the compose file the gem really uses"
  task config: :environment do
    Dockside::Commands.config
  end
end
