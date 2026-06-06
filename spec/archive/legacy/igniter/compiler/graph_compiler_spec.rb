# frozen_string_literal: true

require "spec_helper"

RSpec.describe Igniter::Compiler::GraphCompiler do
  it "compiles a graph with deterministic resolution order" do
    graph = Igniter::Model::Graph.new(
      name: "PriceGraph",
      nodes: [
        Igniter::Model::InputNode.new(id: "1", name: :country),
        Igniter::Model::InputNode.new(id: "2", name: :order_total),
        Igniter::Model::ComputeNode.new(id: "3", name: :vat_rate, dependencies: [:country], callable: ->(country:) { country == "UA" ? 0.2 : 0.0 }),
        Igniter::Model::ComputeNode.new(id: "4", name: :gross_total, dependencies: %i[order_total vat_rate], callable: ->(order_total:, vat_rate:) { order_total * (1 + vat_rate) }),
        Igniter::Model::OutputNode.new(id: "5", name: :gross_total, source: :gross_total)
      ]
    )

    compiled = described_class.call(graph)

    expect(compiled.outputs.map(&:name)).to eq([:gross_total])
    expect(compiled.resolution_order.map(&:name)).to eq(%i[country order_total vat_rate gross_total])
  end

  it "raises on missing dependencies" do
    graph = Igniter::Model::Graph.new(
      name: "BrokenGraph",
      nodes: [
        Igniter::Model::ComputeNode.new(id: "1", name: :gross_total, dependencies: [:vat_rate], callable: ->(vat_rate:) { vat_rate }),
        Igniter::Model::OutputNode.new(id: "2", name: :gross_total, source: :gross_total)
      ]
    )

    expect { described_class.call(graph) }
      .to raise_error(Igniter::ValidationError, /Unknown dependency 'vat_rate'/)
  end

  it "raises on duplicate output names" do
    graph = Igniter::Model::Graph.new(
      name: "BrokenGraph",
      nodes: [
        Igniter::Model::InputNode.new(id: "1", name: :country),
        Igniter::Model::OutputNode.new(id: "2", name: :country, source: :country),
        Igniter::Model::OutputNode.new(id: "3", name: :country, source: :country)
      ]
    )

    expect { described_class.call(graph) }
      .to raise_error(Igniter::ValidationError, /Duplicate output name: country/)
  end

  it "raises on duplicate node ids" do
    graph = Igniter::Model::Graph.new(
      name: "BrokenGraph",
      nodes: [
        Igniter::Model::InputNode.new(id: "dup", name: :country),
        Igniter::Model::InputNode.new(id: "dup", name: :order_total),
        Igniter::Model::OutputNode.new(id: "3", name: :country, source: :country)
      ]
    )

    expect { described_class.call(graph) }
      .to raise_error(Igniter::ValidationError, /Duplicate node id: dup/)
  end

  it "raises on duplicate node paths" do
    first = Igniter::Model::InputNode.new(id: "1", name: :country)
    duplicate_path = Igniter::Model::InputNode.new(id: "2", name: :region, metadata: { source_location: "spec.rb" })
    duplicate_path.instance_variable_set(:@path, first.path)

    graph = Igniter::Model::Graph.new(
      name: "BrokenGraph",
      nodes: [
        first,
        duplicate_path,
        Igniter::Model::OutputNode.new(id: "3", name: :country, source: :country)
      ]
    )

    expect { described_class.call(graph) }
      .to raise_error(Igniter::ValidationError, /Duplicate node path: country/)
  end

  it "includes source location in validation errors for DSL-defined graphs" do
    expect do
      Igniter.compile do
        compute :gross_total, depends_on: [:missing_dep] do |missing_dep:|
          missing_dep
        end
        output :gross_total
      end
    end.to raise_error(Igniter::ValidationError, /location=.*graph_compiler_spec\.rb/)
  end

  it "attaches graph and node context to validation errors" do
    expect do
      Igniter.compile do
        compute :gross_total, depends_on: [:missing_dep] do |missing_dep:|
          missing_dep
        end
        output :gross_total
      end
    end.to raise_error(Igniter::ValidationError) { |error|
      expect(error.graph).to eq("AnonymousContract")
      expect(error.node_name).to eq(:gross_total)
      expect(error.node_path).to eq("gross_total")
      expect(error.source_location).to include("graph_compiler_spec.rb")
      expect(error.message).to include("graph=AnonymousContract")
      expect(error.message).to include("node=gross_total")
    }
  end

  it "rejects compute blocks with positional parameters" do
    expect do
      Igniter.compile do
        input :order_total
        compute :gross_total, depends_on: [:order_total] do |order_total|
          order_total * 1.2
        end
        output :gross_total
      end
    end.to raise_error(Igniter::ValidationError, /must use keyword arguments/i)
  end

  it "rejects compute blocks that require undeclared dependencies" do
    expect do
      Igniter.compile do
        input :order_total
        input :vat_rate
        compute :gross_total, depends_on: [:order_total] do |order_total:, vat_rate:|
          order_total * (1 + vat_rate)
        end
        output :gross_total
      end
    end.to raise_error(Igniter::ValidationError, /requires undeclared dependencies: vat_rate/i)
  end

  it "rejects compute blocks that cannot accept declared dependencies" do
    expect do
      Igniter.compile do
        input :order_total
        input :vat_rate
        compute :gross_total, depends_on: %i[order_total vat_rate] do |order_total:|
          order_total
        end
        output :gross_total
      end
    end.to raise_error(Igniter::ValidationError, /declares unsupported dependencies.*vat_rate/i)
  end
end
