# frozen_string_literal: true

require "bundler/gem_tasks"
require "fileutils"
require "open3"
require "rspec/core/rake_task"
require "rubocop/rake_task"
require_relative "lib/igniter/version"

RuboCop::RakeTask.new do |task|
  active_ruby_paths = %w[
    Gemfile
    Rakefile
    igniter.gemspec
    lib/igniter.rb
    lib/igniter/cluster.rb
    lib/igniter/errors.rb
    lib/igniter/monorepo_packages.rb
    lib/igniter/version.rb
    spec/current/**/*_spec.rb
    packages/igniter-contracts/**/*.rb
    packages/igniter-embed/**/*.rb
    packages/igniter-extensions/**/*.rb
    packages/igniter-application/**/*.rb
    packages/igniter-ai/**/*.rb
    packages/igniter-agents/**/*.rb
    packages/igniter-hub/**/*.rb
    packages/igniter-ledger-client/**/*.rb
    packages/igniter-web/**/*.rb
    packages/igniter-cluster/**/*.rb
    packages/igniter-mcp-adapter/**/*.rb
  ]
  task.patterns = active_ruby_paths
  task.options = ["--cache-root", File.expand_path(".rubocop_cache", __dir__)]
end

RSpec::Core::RakeTask.new(:spec) do |t|
  active_spec_roots = %w[
    spec/current
    packages/igniter-contracts/spec
    packages/igniter-embed/spec
    packages/igniter-extensions/spec
    packages/igniter-application/spec
    packages/igniter-ai/spec
    packages/igniter-agents/spec
    packages/igniter-hub/spec
    packages/igniter-ledger-client/spec
    packages/igniter-web/spec
    packages/igniter-cluster/spec
    packages/igniter-mcp-adapter/spec
  ]
  t.pattern = "{#{active_spec_roots.join(",")}}/**/*_spec.rb"
end

RSpec::Core::RakeTask.new(:architecture) do |t|
  t.pattern = %w[
    packages/igniter-contracts/spec/igniter/contracts/layer_boundaries_spec.rb
    packages/igniter-extensions/spec/igniter/extensions/contracts/public_boundary_spec.rb
  ].join(",")
end

task :examples do
  ruby "examples/run.rb", "smoke"
end

namespace :local do
  desc "Rebuild and reinstall the local igniter gem, then remove built .gem artifacts"
  task :install do
    gem_name = "igniter"
    gem_file = "#{gem_name}-#{Igniter::VERSION}.gem"
    run_unbundled = lambda do |*command|
      Bundler.with_unbundled_env do
        system(*command, exception: false)
      end
    end
    capture_unbundled = lambda do |*command|
      Bundler.with_unbundled_env do
        Open3.capture2e(*command)
      end
    end

    FileUtils.rm_f(Dir["#{gem_name}-*.gem"])

    _output, installed_status = capture_unbundled.call("gem", "list", "-i", gem_name)
    installed = installed_status.success?

    if installed
      uninstall_result = run_unbundled.call("gem", "uninstall", gem_name, "-aIx")
      raise "Failed to uninstall #{gem_name}" unless uninstall_result
    else
      puts "igniter gem was not installed; continuing with a fresh install"
    end

    raise "Failed to build #{gem_file}" unless run_unbundled.call("gem", "build", "igniter.gemspec")
    raise "Failed to install #{gem_file}" unless run_unbundled.call("gem", "install", "./#{gem_file}", "--no-document")
  ensure
    FileUtils.rm_f(Dir["#{gem_name}-*.gem"])
  end
end

task default: %i[spec rubocop]
