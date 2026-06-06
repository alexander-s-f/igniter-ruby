# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter dependency boundaries" do
  BOUNDARY_ROOT = File.expand_path("../..", __dir__)

  def ruby_files_for(*patterns)
    patterns.flat_map { |pattern| Dir.glob(File.join(BOUNDARY_ROOT, pattern)) }.sort
  end

  def require_lines_for(files)
    files.each_with_object({}) do |file, map|
      lines = File.readlines(file, chomp: true).filter_map do |line|
        stripped = line.strip
        stripped if stripped.start_with?("require ", "require_relative ")
      end
      map[file] = lines unless lines.empty?
    end
  end

  def offenders_for(require_map, patterns)
    require_map.each_with_object({}) do |(file, lines), offenders|
      matches = lines.select { |line| patterns.any? { |pattern| line.match?(pattern) } }
      offenders[file] = matches unless matches.empty?
    end
  end

  def format_offenders(offenders)
    offenders.map do |file, lines|
      "#{file.sub("#{BOUNDARY_ROOT}/", "")}:\n  #{lines.join("\n  ")}"
    end.join("\n")
  end

  it "does not let core files require sdk or plugin code" do
    files = ruby_files_for("packages/igniter-core/lib/igniter/core.rb", "packages/igniter-core/lib/igniter/core/**/*.rb")
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/agent(?:s|["'])/,
        /require\s+["']igniter\/sdk\//,
        /require\s+["']igniter\/plugins\//,
        /require_relative\s+["'][^"']*agent(?:s)?(?:\/|["'])/,
        /require_relative\s+["'][^"']*sdk(?:\/|["'])/,
        /require_relative\s+["'][^"']*plugins(?:\/|["'])/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      Core must not depend on agents/*, sdk/*, or plugins/*.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "does not let agents, sdk, or ai package files require plugin code" do
    files = ruby_files_for(
      "packages/igniter-agents/lib/igniter-agents.rb",
      "packages/igniter-agents/lib/igniter/**/*.rb",
      "packages/igniter-sdk/lib/igniter/sdk.rb",
      "packages/igniter-sdk/lib/igniter/sdk/**/*.rb",
      "packages/igniter-ai/lib/igniter/ai.rb",
      "packages/igniter-ai/lib/igniter/ai/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/plugins\//,
        /require_relative\s+["'][^"']*plugins(?:\/|["'])/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      agents/*, sdk/*, and igniter-ai must not depend on plugins/*.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "keeps sdk and ai packages on stable root entrypoints for shared primitives" do
    files = ruby_files_for(
      "packages/igniter-sdk/lib/igniter/sdk.rb",
      "packages/igniter-sdk/lib/igniter/sdk/**/*.rb",
      "packages/igniter-ai/lib/igniter/ai.rb",
      "packages/igniter-ai/lib/igniter/ai/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core\/errors["']/,
        /require\s+["']igniter\/core\/tool["']/,
        /require\s+["']igniter\/core\/effect["']/,
        /require_relative\s+["'][^"']*igniter\/core\/errors["']/,
        /require_relative\s+["'][^"']*igniter\/core\/tool["']/,
        /require_relative\s+["'][^"']*igniter\/core\/effect["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      sdk/* and igniter-ai should depend on stable root entrypoints for shared
      primitives (`igniter/errors`, `igniter/tool`, `igniter/effect`) rather
      than reaching directly into core file paths.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "keeps agents and server packages on stable root error entrypoints" do
    files = ruby_files_for(
      "packages/igniter-agents/lib/igniter/**/*.rb",
      "packages/igniter-server/lib/igniter/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core\/errors["']/,
        /require_relative\s+["'][^"']*igniter\/core\/errors["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      agents/* and server/* should use the stable root error entrypoint
      (`igniter/errors`) instead of reaching directly into igniter/core/errors.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "keeps agents on the stable root agent-adapter entrypoint" do
    files = ruby_files_for(
      "packages/igniter-agents/lib/igniter/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core\/runtime\/agent_adapter["']/,
        /require_relative\s+["'][^"']*igniter\/core\/runtime\/agent_adapter["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      agents/* should use the stable root agent-adapter entrypoint
      (`igniter/runtime/agent_adapter`) instead of reaching directly into
      `igniter/core/runtime/agent_adapter`.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "keeps root, server, cluster, and app layers on stable root contract/runtime/diagnostics entrypoints" do
    files = ruby_files_for(
      "lib/igniter.rb",
      "packages/igniter-server/lib/igniter/**/*.rb",
      "packages/igniter-cluster/lib/igniter/**/*.rb",
      "packages/igniter-app/lib/igniter/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core\/contract["']/,
        /require\s+["']igniter\/core\/runtime["']/,
        /require\s+["']igniter\/core\/diagnostics["']/,
        /require_relative\s+["'][^"']*igniter\/core\/contract["']/,
        /require_relative\s+["'][^"']*igniter\/core\/runtime["']/,
        /require_relative\s+["'][^"']*igniter\/core\/diagnostics["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      The root facade and upper runtime-hosting packages should depend on
      stable root entrypoints (`igniter/contract`, `igniter/runtime`,
      `igniter/diagnostics`) instead of reaching directly into
      `igniter/core/*` file paths.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "keeps upper packages off direct igniter/core feature paths when legacy wrappers exist" do
    files = ruby_files_for(
      "packages/igniter-cluster/lib/igniter/**/*.rb",
      "packages/igniter-server/lib/igniter/**/*.rb",
      "packages/igniter-sdk/lib/igniter/**/*.rb",
      "packages/igniter-app/lib/igniter/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core["']/,
        /require\s+["']igniter\/core\/dsl["']/,
        /require\s+["']igniter\/core\/model["']/,
        /require\s+["']igniter\/core\/compiler["']/,
        /require\s+["']igniter\/core\/type_system["']/,
        /require\s+["']igniter\/core\/memory["']/,
        /require\s+["']igniter\/core\/metrics["']/,
        /require_relative\s+["'][^"']*igniter\/core["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      Upper packages should prefer `igniter/legacy` and focused
      `igniter/legacy/*` wrappers over direct `igniter/core*` feature paths.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "does not let rails integration files require app, server, or cluster layers" do
    files = ruby_files_for(
      "packages/igniter-rails/lib/igniter-rails.rb",
      "packages/igniter-rails/lib/igniter/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/app(?:\/|["'])/,
        /require\s+["']igniter\/server(?:\/|["'])/,
        /require\s+["']igniter\/cluster(?:\/|["'])/,
        /require\s+["']igniter-app["']/,
        /require\s+["']igniter-server["']/,
        /require\s+["']igniter-cluster["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      igniter-rails must stay an integration over the embedded kernel and must
      not depend on app/server/cluster layers.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "does not let igniter-contracts require igniter-core implementation entrypoints" do
    files = ruby_files_for(
      "packages/igniter-contracts/lib/igniter-contracts.rb",
      "packages/igniter-contracts/lib/igniter/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core(?:\/|["'])/,
        /require\s+["']igniter-core["']/,
        /require_relative\s+["'][^"']*igniter\/core(?:\/|["'])/,
        /require_relative\s+["'][^"']*igniter-core["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      igniter-contracts must not depend on igniter-core implementation entrypoints.
      The legacy core stays in the monorepo only as a reference implementation
      and parity baseline while igniter-contracts matures into the replacement.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end

  it "keeps the contracts-facing igniter-extensions surface free from legacy core requires" do
    files = ruby_files_for(
      "packages/igniter-extensions/lib/igniter-extensions.rb",
      "packages/igniter-extensions/lib/igniter/extensions.rb",
      "packages/igniter-extensions/lib/igniter/extensions/contracts.rb",
      "packages/igniter-extensions/lib/igniter/extensions/contracts/**/*.rb"
    )
    offenders = offenders_for(
      require_lines_for(files),
      [
        /require\s+["']igniter\/core(?:\/|["'])/,
        /require\s+["']igniter-core["']/,
        /require\s+["']igniter["']/,
        /require_relative\s+["'][^"']*igniter\/core(?:\/|["'])/,
        /require_relative\s+["'][^"']*igniter-core["']/,
        /require_relative\s+["'][^"']*igniter["']/
      ]
    )

    expect(offenders).to eq({}), <<~MSG
      The contracts-facing igniter-extensions surface must stay on top of
      igniter-contracts only and must not pull the legacy core or umbrella
      runtime implicitly.

      Offending require statements:
      #{format_offenders(offenders)}
    MSG
  end
end
