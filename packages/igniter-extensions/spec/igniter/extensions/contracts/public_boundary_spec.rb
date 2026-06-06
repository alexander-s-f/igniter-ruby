# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe "Igniter::Extensions::Contracts public boundaries" do
  EXTENSIONS_ROOT = File.expand_path("../../../../lib/igniter/extensions", __dir__)

  def contracts_surface_files
    [
      File.join(EXTENSIONS_ROOT, "contracts.rb"),
      *Dir.glob(File.join(EXTENSIONS_ROOT, "contracts/**/*.rb"))
    ].sort
  end

  def require_lines_for(file)
    File.readlines(file, chomp: true).filter_map do |line|
      stripped = line.strip
      stripped if stripped.start_with?("require ", "require_relative ")
    end
  end

  it "depends on igniter-contracts only through the public entrypoint" do
    offenders = contracts_surface_files.each_with_object({}) do |file, memo|
      matches = require_lines_for(file).select do |line|
        line.match?(%r{require\s+["']igniter/contracts/(assembly|execution)}) ||
          line.match?(%r{require_relative\s+["'][^"']*igniter/contracts/(assembly|execution)})
      end
      memo[file] = matches unless matches.empty?
    end

    expect(offenders).to eq({})
  end

  it "does not reference Igniter::Contracts internal namespaces" do
    offenders = contracts_surface_files.each_with_object({}) do |file, memo|
      matches = File.read(file).scan(/\bIgniter::Contracts::(?:Assembly|Execution)\b/).uniq
      memo[file] = matches unless matches.empty?
    end

    expect(offenders).to eq({})
  end

  it "does not hardcode lowered extension DSL as raw operation kinds" do
    lowered_kinds = %w[branch lookup count sum avg].freeze

    offenders = contracts_surface_files.each_with_object({}) do |file, memo|
      matches = File.read(file).scan(/add_operation\(\s*kind:\s*:(branch|lookup|count|sum|avg)/).flatten.uniq.sort
      memo[file] = matches if (matches & lowered_kinds).any?
    end

    expect(offenders).to eq({})
  end
end
