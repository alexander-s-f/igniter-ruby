# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/capabilities"

RSpec.describe Igniter::Capabilities do
  after { Igniter::Capabilities.policy = nil }

  # ─── Executor DSL ─────────────────────────────────────────────────────────

  describe "Executor DSL" do
    let(:klass) { Class.new(Igniter::Executor) }

    it "defaults to empty capabilities" do
      expect(klass.declared_capabilities).to eq([])
    end

    it "stores declared capabilities as frozen array of symbols" do
      klass.capabilities(:network, :external_api)
      expect(klass.declared_capabilities).to eq(%i[network external_api])
      expect(klass.declared_capabilities).to be_frozen
    end

    it "accumulates capabilities across multiple calls" do
      klass.capabilities(:network)
      klass.capabilities(:database)
      expect(klass.declared_capabilities).to eq(%i[network database])
    end

    it "deduplicates capabilities" do
      klass.capabilities(:network, :network)
      expect(klass.declared_capabilities.count(:network)).to eq(1)
    end

    it "pure shorthand adds :pure capability" do
      klass.pure
      expect(klass.declared_capabilities).to include(:pure)
      expect(klass.pure?).to be true
    end

    it "pure? returns false for non-pure executors" do
      klass.capabilities(:network)
      expect(klass.pure?).to be false
    end

    it "does not inherit capabilities from parent" do
      parent = Class.new(Igniter::Executor) { capabilities(:network) }
      child  = Class.new(parent)
      expect(child.declared_capabilities).to eq([])
    end
  end

  # ─── Policy ───────────────────────────────────────────────────────────────

  describe Igniter::Capabilities::Policy do
    let(:network_executor) do
      Class.new(Igniter::Executor) do
        capabilities :network, :external_api

        def call(**); end
      end
    end

    let(:pure_executor) do
      Class.new(Igniter::Executor) do
        pure

        def call(**); end
      end
    end

    it "passes when no capabilities are denied" do
      policy = described_class.new(denied: [])
      expect { policy.check!(:node, network_executor) }.not_to raise_error
    end

    it "raises CapabilityViolationError when a denied capability is used" do
      policy = described_class.new(denied: [:network])
      expect { policy.check!(:payment, network_executor) }
        .to raise_error(Igniter::Capabilities::CapabilityViolationError, /network/)
    end

    it "includes the node name in the error" do
      policy = described_class.new(denied: [:external_api])
      expect { policy.check!(:payment, network_executor) }
        .to raise_error(Igniter::Capabilities::CapabilityViolationError, /payment/)
    end

    it "allows pure executors through a network-denying policy" do
      policy = described_class.new(denied: [:network])
      expect { policy.check!(:tax, pure_executor) }.not_to raise_error
    end
  end

  # ─── CompiledGraph integration ────────────────────────────────────────────

  describe "CompiledGraph#required_capabilities" do
    let(:pure_exec) do
      Class.new(Igniter::Executor) do
        pure

        def call(x:) = x * 2
      end
    end

    let(:net_exec) do
      Class.new(Igniter::Executor) do
        capabilities :network

        def call(x:) = x
      end
    end

    it "returns capabilities for each compute node" do
      pe = pure_exec
      ne = net_exec

      contract = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :doubled, depends_on: :x, call: pe
          compute :fetched, depends_on: :x, call: ne
          output :doubled
          output :fetched
        end
      end

      caps = contract.compiled_graph.required_capabilities
      expect(caps[:doubled]).to include(:pure)
      expect(caps[:fetched]).to include(:network)
    end

    it "excludes nodes with no declared capabilities" do
      contract = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :y, depends_on: :x do |x:| x + 1 end
          output :y
        end
      end

      expect(contract.compiled_graph.required_capabilities).to be_empty
    end

    it "capabilities_for returns capabilities for a single node" do
      pe = pure_exec
      contract = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :doubled, depends_on: :x, call: pe
          output :doubled
        end
      end

      expect(contract.compiled_graph.capabilities_for(:doubled)).to include(:pure)
      expect(contract.compiled_graph.capabilities_for(:x)).to eq([])
    end
  end

  # ─── Runtime enforcement ──────────────────────────────────────────────────

  describe "runtime policy enforcement" do
    let(:network_executor) do
      Class.new(Igniter::Executor) do
        capabilities :network

        def call(x:) = x
      end
    end

    let(:contract_class) do
      ne = network_executor
      Class.new(Igniter::Contract) do
        define do
          input :x
          compute :result, depends_on: :x, call: ne
          output :result
        end
      end
    end

    it "raises at resolution time when policy denies a capability" do
      Igniter::Capabilities.policy = Igniter::Capabilities::Policy.new(denied: [:network])

      expect { contract_class.new(x: 1).resolve_all }
        .to raise_error(Igniter::Capabilities::CapabilityViolationError, /network/)
    end

    it "executes normally when no policy is set" do
      Igniter::Capabilities.policy = nil
      contract = contract_class.new(x: 42)
      contract.resolve_all
      expect(contract.result.result).to eq(42)
    end
  end
end
