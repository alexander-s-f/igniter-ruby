# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter namespace ownership" do
  OWNERSHIP_ROOT = File.expand_path("../..", __dir__)

  NAMESPACE_RULES = {
    "Igniter::AI" => {
      roots: [
        "packages/igniter-ai/lib/igniter/ai.rb",
        "packages/igniter-ai/lib/igniter/ai/",
        "packages/igniter-agents/lib/igniter/ai/agents.rb",
        "packages/igniter-agents/lib/igniter/ai/agents/"
      ],
      patterns: [
        /module\s+Igniter::AI\b/,
        /class\s+Igniter::AI\b/,
        /module\s+Igniter\b\s*module\s+AI\b/m
      ]
    },
    "Igniter::Agents" => {
      roots: [
        "packages/igniter-agents/lib/igniter/agents.rb",
        "packages/igniter-agents/lib/igniter/agents/"
      ],
      patterns: [
        /module\s+Igniter::Agents\b/,
        /class\s+Igniter::Agents\b/,
        /module\s+Igniter\b\s*module\s+Agents\b/m
      ]
    },
    "Igniter::Channels" => {
      roots: [
        "packages/igniter-sdk/lib/igniter/sdk/channels.rb",
        "packages/igniter-sdk/lib/igniter/sdk/channels/"
      ],
      patterns: [
        /module\s+Igniter::Channels\b/,
        /class\s+Igniter::Channels\b/,
        /module\s+Igniter\b\s*module\s+Channels\b/m
      ]
    },
    "Igniter::Data" => {
      roots: [
        "packages/igniter-sdk/lib/igniter/sdk/data.rb",
        "packages/igniter-sdk/lib/igniter/sdk/data/"
      ],
      patterns: [
        /module\s+Igniter::Data\b/,
        /class\s+Igniter::Data\b/,
        /module\s+Igniter\b\s*module\s+Data\b/m
      ]
    },
    "Igniter::Extensions" => {
      roots: [
        "packages/igniter-core/lib/igniter/core/extensions.rb",
        "packages/igniter-core/lib/igniter/core/extensions/",
        "packages/igniter-extensions/lib/igniter/extensions.rb",
        "packages/igniter-extensions/lib/igniter/extensions/"
      ],
      patterns: [
        /module\s+Igniter::Extensions\b/,
        /class\s+Igniter::Extensions\b/,
        /module\s+Igniter\b\s*module\s+Extensions\b/m
      ]
    },
    "Igniter::App" => {
      roots: [
        "packages/igniter-app/lib/igniter/app.rb",
        "packages/igniter-app/lib/igniter/app/"
      ],
      patterns: [
        /class\s+Igniter::App\b/,
        /module\s+Igniter\b\s*class\s+App\b/m,
        /class\s+App\s*</
      ]
    },
    "Igniter::Application" => {
      roots: [
        "packages/igniter-application/lib/igniter/application.rb",
        "packages/igniter-application/lib/igniter/application/"
      ],
      patterns: [
        /module\s+Igniter::Application\b/,
        /class\s+Igniter::Application\b/,
        /module\s+Igniter\b\s*module\s+Application\b/m
      ]
    },
    "Igniter::Server" => {
      roots: [
        "packages/igniter-server/lib/igniter/server.rb",
        "packages/igniter-server/lib/igniter/server/"
      ],
      patterns: [
        /module\s+Igniter::Server\b/,
        /class\s+Igniter::Server\b/,
        /module\s+Igniter\b\s*module\s+Server\b/m
      ]
    },
    "Igniter::Cluster" => {
      roots: [
        "packages/igniter-cluster/lib/igniter/cluster.rb",
        "packages/igniter-cluster/lib/igniter/cluster/"
      ],
      patterns: [
        /module\s+Igniter::Cluster\b/,
        /class\s+Igniter::Cluster\b/,
        /module\s+Igniter\b\s*module\s+Cluster\b/m
      ]
    },
    "Igniter::Rails" => {
      roots: [
        "packages/igniter-rails/lib/igniter/plugins/rails.rb",
        "packages/igniter-rails/lib/igniter/plugins/rails/"
      ],
      patterns: [
        /module\s+Igniter::Rails\b/,
        /class\s+Igniter::Rails\b/,
        /module\s+Igniter\b\s*module\s+Rails\b/m
      ]
    },
    "Igniter::Frontend" => {
      roots: [
        "packages/igniter-frontend/lib/igniter-frontend.rb",
        "packages/igniter-frontend/lib/igniter/frontend.rb",
        "packages/igniter-frontend/lib/igniter/frontend/"
      ],
      patterns: [
        /module\s+Igniter::Frontend\b/,
        /class\s+Igniter::Frontend\b/,
        /module\s+Igniter\b\s*module\s+Frontend\b/m
      ]
    },
    "Igniter::SchemaRendering" => {
      roots: [
        "packages/igniter-schema-rendering/lib/igniter-schema-rendering.rb",
        "packages/igniter-schema-rendering/lib/igniter/schema_rendering.rb",
        "packages/igniter-schema-rendering/lib/igniter/schema_rendering/"
      ],
      patterns: [
        /module\s+Igniter::SchemaRendering\b/,
        /class\s+Igniter::SchemaRendering\b/,
        /module\s+Igniter\b\s*module\s+SchemaRendering\b/m
      ]
    }
  }.freeze

  def ruby_lib_files
    Dir.glob(File.join(OWNERSHIP_ROOT, "{lib,packages}/**/*.rb")).sort
  end

  def relative_path(path)
    path.sub("#{OWNERSHIP_ROOT}/", "")
  end

  def uncommented_source_for(path)
    File.readlines(path, chomp: true)
        .reject { |line| line.lstrip.start_with?("#") }
        .join("\n")
  end

  def owned_by_roots?(relative_file, roots)
    roots.any? do |root|
      root.end_with?("/") ? relative_file.start_with?(root) : relative_file == root
    end
  end

  def offenders_for(rule)
    ruby_lib_files.each_with_object([]) do |file, offenders|
      relative_file = relative_path(file)
      next if owned_by_roots?(relative_file, rule.fetch(:roots))

      source = uncommented_source_for(file)
      next unless rule.fetch(:patterns).any? { |pattern| source.match?(pattern) }

      offenders << relative_file
    end
  end

  NAMESPACE_RULES.each do |namespace, rule|
    it "keeps #{namespace} definitions inside its canonical roots" do
      expect(offenders_for(rule)).to eq([]), <<~MSG
        #{namespace} must be defined only inside:
        #{rule.fetch(:roots).join("\n")}

        Offending files:
        #{offenders_for(rule).join("\n")}
      MSG
    end
  end
end
