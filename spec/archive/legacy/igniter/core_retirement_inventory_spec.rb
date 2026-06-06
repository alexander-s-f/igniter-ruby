# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter core retirement inventory" do
  ROOT = File.expand_path("../..", __dir__)

  def gemspecs
    Dir.glob(File.join(ROOT, "packages/*/*.gemspec")).sort
  end

  def package_name_for(path)
    relative = path.delete_prefix("#{ROOT}/")
    relative.split("/")[1]
  end

  def file_text(path)
    File.read(path)
  end

  it "keeps package-level igniter-core runtime dependencies on an explicit retirement whitelist" do
    expected = %w[
      igniter-app
      igniter-cluster
      igniter-extensions
      igniter-rails
      igniter-server
    ].freeze

    actual = gemspecs.filter_map do |path|
      package_name_for(path) if file_text(path).include?('add_dependency "igniter-core"')
    end.sort

    expect(actual).to eq(expected), <<~MSG
      The igniter-core retirement whitelist changed.

      If this was intentional, update the whitelist and the retirement inventory:
      docs/dev/core-retirement-inventory.md

      Current packages depending on igniter-core:
      #{actual.join("\n")}
    MSG
  end

  it "keeps package-level igniter-legacy runtime dependencies on an explicit migration whitelist" do
    expected = %w[
      igniter-agents
      igniter-ai
      igniter-sdk
    ].freeze

    actual = gemspecs.filter_map do |path|
      package_name_for(path) if file_text(path).include?('add_dependency "igniter-legacy"')
    end.sort

    expect(actual).to eq(expected), <<~MSG
      The igniter-legacy migration whitelist changed.

      If this was intentional, update the whitelist and the retirement inventory:
      docs/dev/core-retirement-inventory.md

      Current packages depending on igniter-legacy:
      #{actual.join("\n")}
    MSG
  end

  it "keeps package metadata version-coupling to igniter-core on an explicit whitelist" do
    expected = [].freeze

    actual = gemspecs.filter_map do |path|
      package_name_for(path) if file_text(path).include?('require_relative "../igniter-core/lib/igniter/core/version"')
    end.sort

    expect(actual).to eq(expected), <<~MSG
      The package metadata version-coupling whitelist changed.

      If this was intentional, update the whitelist and the retirement inventory:
      docs/dev/core-retirement-inventory.md

      Current packages loading version metadata from igniter-core:
      #{actual.join("\n")}
    MSG
  end

  it "keeps lib-level core version loading isolated to the current retirement whitelist" do
    expected = [].freeze

    actual = Dir.glob(File.join(ROOT, "packages/*/lib/**/*.rb")).filter_map do |path|
      package_name_for(path) if file_text(path).include?('require "igniter/core/version"')
    end.uniq.sort

    expect(actual).to eq(expected), <<~MSG
      The lib-level igniter/core/version whitelist changed.

      If this was intentional, update the whitelist and the retirement inventory:
      docs/dev/core-retirement-inventory.md

      Current packages loading igniter/core/version from lib files:
      #{actual.join("\n")}
    MSG
  end
end
