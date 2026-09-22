require "spec_helper"

ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"
require "rspec/rails"
require "rake"

module RailsWorld
  # Loads the rake tasks the way a Rails app does, once for the whole suite.
  def load_the_rake_tasks
    return if Rake::Task.task_defined?("dockside:up")

    Rake::Task.define_task(:environment)
    Rails.application.load_tasks
  end
end

RSpec.configure do |config|
  config.include RailsWorld
end
