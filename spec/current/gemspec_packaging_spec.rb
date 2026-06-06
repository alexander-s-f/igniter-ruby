# frozen_string_literal: true

require "spec_helper"

RSpec.describe "gemspec packaging" do
  def load_gemspec(path)
    absolute_path = File.join(File.expand_path("../..", __dir__), path)

    Dir.chdir(File.dirname(absolute_path)) do
      Gem::Specification.load(File.basename(absolute_path))
    end
  end

  it "ships only the current root package graph in the umbrella gem" do
    spec = load_gemspec("igniter.gemspec")

    expect(spec.files).to include("packages/igniter-contracts/lib/igniter/contracts.rb")
    expect(spec.files).to include("packages/igniter-embed/lib/igniter/embed.rb")
    expect(spec.files).to include("packages/igniter-extensions/lib/igniter/extensions/contracts.rb")
    expect(spec.files).to include("packages/igniter-application/lib/igniter/application.rb")
    expect(spec.files).to include("packages/igniter-ai/lib/igniter/ai.rb")
    expect(spec.files).to include("packages/igniter-agents/lib/igniter/agents.rb")
    expect(spec.files).to include("packages/igniter-hub/lib/igniter/hub.rb")
    expect(spec.files).to include("packages/igniter-web/lib/igniter/web.rb")
    expect(spec.files).to include("packages/igniter-cluster/lib/igniter/cluster.rb")
    expect(spec.files).to include("packages/igniter-mcp-adapter/lib/igniter/mcp/adapter.rb")
    expect(spec.files.grep(%r{examples/archive})).to eq([])
    expect(spec.require_paths).not_to include("packages/archive/igniter-core/lib")
  end

  it "keeps igniter-extensions free from igniter-core runtime dependency" do
    spec = load_gemspec("packages/igniter-extensions/igniter-extensions.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq(["igniter-contracts"])
  end

  it "declares igniter-embed runtime dependency through igniter-contracts only" do
    spec = load_gemspec("packages/igniter-embed/igniter-embed.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq(%w[igniter-contracts igniter-extensions])
  end

  it "declares igniter-application runtime dependencies through current package layers only" do
    spec = load_gemspec("packages/igniter-application/igniter-application.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq(%w[igniter-contracts igniter-extensions igniter-ai igniter-agents])
  end

  it "declares igniter-agents runtime dependency through igniter-ai only" do
    spec = load_gemspec("packages/igniter-agents/igniter-agents.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq(["igniter-ai"])
  end

  it "keeps igniter-hub free from runtime dependencies" do
    spec = load_gemspec("packages/igniter-hub/igniter-hub.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq([])
  end

  it "declares igniter-cluster runtime dependency through igniter-application only" do
    spec = load_gemspec("packages/igniter-cluster/igniter-cluster.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq(["igniter-application"])
  end

  it "declares igniter-web runtime dependency through igniter-application only" do
    spec = load_gemspec("packages/igniter-web/igniter-web.gemspec")

    dependency_names = spec.dependencies.select { |dependency| dependency.type == :runtime }.map(&:name)
    expect(dependency_names).to eq(%w[arbre igniter-application])
  end
end
