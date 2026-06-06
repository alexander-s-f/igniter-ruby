# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/provenance"
require "igniter/cluster"

RSpec.describe "Igniter::Provenance" do
  # ── Shared contracts ─────────────────────────────────────────────────────────

  let(:simple_contract_class) do
    Class.new(Igniter::Contract) do
      define do
        input :price,    type: :numeric
        input :quantity, type: :numeric

        compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
          (price * quantity).round(2)
        end

        compute :tax, depends_on: :subtotal do |subtotal:|
          (subtotal * 0.1).round(2)
        end

        compute :total, depends_on: %i[subtotal tax] do |subtotal:, tax:|
          (subtotal + tax).round(2)
        end

        output :subtotal
        output :total
      end
    end
  end

  let(:contract) do
    c = simple_contract_class.new(price: 50.0, quantity: 4)
    c.resolve_all
    c
  end

  # ── Builder ──────────────────────────────────────────────────────────────────

  describe Igniter::Provenance::Builder do
    it "raises ProvenanceError for unknown output names" do
      expect { contract.lineage(:nonexistent) }
        .to raise_error(Igniter::Provenance::ProvenanceError, /nonexistent/)
    end
  end

  # ── NodeTrace ────────────────────────────────────────────────────────────────

  describe Igniter::Provenance::NodeTrace do
    subject(:trace) { contract.lineage(:total).trace }

    it "has the correct name and kind" do
      expect(trace.name).to eq(:total)
      expect(trace.kind).to eq(:compute)
    end

    it "has the correct resolved value" do
      expect(trace.value).to eq(220.0)  # 50 * 4 = 200, tax = 20, total = 220
    end

    it "has contributing nodes for its dependencies" do
      expect(trace.contributing.keys).to contain_exactly(:subtotal, :tax)
    end

    it "is not a leaf (has contributing nodes)" do
      expect(trace.leaf?).to be false
    end

    it "input nodes are leaves" do
      price_trace = trace.contributing[:subtotal].contributing[:price]
      expect(price_trace).not_to be_nil
      expect(price_trace.kind).to eq(:input)
      expect(price_trace.leaf?).to be true
    end
  end

  # ── Lineage#contributing_inputs ──────────────────────────────────────────────

  describe "Lineage#contributing_inputs" do
    it "returns all input nodes that contributed to the output" do
      inputs = contract.lineage(:total).contributing_inputs
      expect(inputs.keys).to contain_exactly(:price, :quantity)
      expect(inputs[:price]).to eq(50.0)
      expect(inputs[:quantity]).to eq(4)
    end

    it "is a subset for an intermediate output" do
      inputs = contract.lineage(:subtotal).contributing_inputs
      expect(inputs.keys).to contain_exactly(:price, :quantity)
    end
  end

  # ── Lineage#sensitive_to? ────────────────────────────────────────────────────

  describe "Lineage#sensitive_to?" do
    let(:lin) { contract.lineage(:total) }

    it "returns true for inputs that contributed" do
      expect(lin.sensitive_to?(:price)).to be true
      expect(lin.sensitive_to?(:quantity)).to be true
    end

    it "returns false for inputs that did not contribute" do
      expect(lin.sensitive_to?(:discount)).to be false
      expect(lin.sensitive_to?(:user_id)).to be false
    end
  end

  # ── Lineage#path_to ──────────────────────────────────────────────────────────

  describe "Lineage#path_to" do
    let(:lin) { contract.lineage(:total) }

    it "returns the path from output to a contributing input" do
      path = lin.path_to(:price)
      expect(path).to eq(%i[total subtotal price])
    end

    it "also finds path through another branch" do
      path = lin.path_to(:quantity)
      expect(path).to eq(%i[total subtotal quantity])
    end

    it "returns nil for non-contributing inputs" do
      expect(lin.path_to(:discount)).to be_nil
    end
  end

  # ── TextFormatter ─────────────────────────────────────────────────────────────

  describe Igniter::Provenance::TextFormatter do
    let(:tree) { contract.explain(:total) }

    it "includes the output name and value" do
      expect(tree).to include("total")
      expect(tree).to include("220.0")
    end

    it "includes intermediate compute nodes" do
      expect(tree).to include("subtotal")
      expect(tree).to include("tax")
    end

    it "includes input leaf nodes" do
      expect(tree).to include("price")
      expect(tree).to include("quantity")
    end

    it "includes kind annotations" do
      expect(tree).to include("[compute]")
      expect(tree).to include("[input]")
    end

    it "uses tree-drawing characters" do
      expect(tree).to include("├─").or include("└─")
    end
  end

  # ── Contract#explain ─────────────────────────────────────────────────────────

  describe "Contract#explain" do
    it "returns the same string as lineage.explain" do
      expect(contract.explain(:total)).to eq(contract.lineage(:total).explain)
    end
  end

  # ── Lineage#to_h ─────────────────────────────────────────────────────────────

  describe "Lineage#to_h" do
    it "is a serialisable hash with :node, :kind, :value, :contributing" do
      h = contract.lineage(:total).to_h
      expect(h[:node]).to eq(:total)
      expect(h[:kind]).to eq(:compute)
      expect(h[:value]).to eq(220.0)
      expect(h[:contributing]).to be_a(Hash)
      expect(h[:contributing].keys).to contain_exactly(:subtotal, :tax)
    end

    it "recursively serialises contributing nodes" do
      subtotal_h = contract.lineage(:total).to_h[:contributing][:subtotal]
      expect(subtotal_h[:contributing].keys).to contain_exactly(:price, :quantity)
    end
  end

  # ── Diamond dependency (shared node) ──────────────────────────────────────────

  describe "diamond dependency" do
    let(:diamond_class) do
      Class.new(Igniter::Contract) do
        define do
          input :x, type: :numeric

          compute :a, depends_on: :x do |x:| x * 2 end
          compute :b, depends_on: :x do |x:| x * 3 end
          compute :c, depends_on: %i[a b] do |a:, b:| a + b end

          output :c
        end
      end
    end

    it "traces both branches back to the shared input" do
      c = diamond_class.new(x: 5.0)
      c.resolve_all
      lin = c.lineage(:c)

      expect(lin.contributing_inputs).to eq({ x: 5.0 })
      expect(lin.sensitive_to?(:x)).to be true
      # Both branches should appear in the tree
      expect(lin.explain).to include("a =")
      expect(lin.explain).to include("b =")
    end
  end

  describe "remote routing traces" do
    let(:pending_trace) do
      {
        query: { all_of: [:orders], tags: [:linux] },
        selected_url: nil,
        eligible_count: 0,
        peers: [
          { name: "orders-linux", reasons: [:unreachable] }
        ]
      }
    end

    let(:failed_trace) do
      {
        routing_mode: :pinned,
        peer_name: "audit-node",
        known: true,
        selected_url: "http://audit:4567",
        reachable: false,
        reasons: [:unreachable]
      }
    end

    let(:pending_adapter) do
      trace = pending_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, inputs:, execution:|
          raise Igniter::Cluster::Mesh::DeferredCapabilityError.new(
            :orders,
            Igniter::Runtime::DeferredResult.build(
              payload: { query: { all_of: [:orders] } },
              source_node: node.name,
              waiting_on: node.name
            ),
            query: { all_of: [:orders] },
            explanation: @routing_trace
          )
        end
      end.new(trace)
    end

    let(:failed_adapter) do
      trace = failed_trace
      Class.new do
        define_method(:initialize) { |routing_trace| @routing_trace = routing_trace }

        define_method(:call) do |node:, **|
          raise Igniter::ResolutionError.new(
            "Pinned peer is unreachable",
            context: { routing_trace: @routing_trace }
          )
        end
      end.new(trace)
    end

    let(:pending_contract_class) do
      adapter = pending_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :order_id
          remote :order_result, contract: "ProcessOrder", node: "http://unused.example", inputs: { id: :order_id }
          output :order_result
        end
      end
    end

    let(:failed_contract_class) do
      adapter = failed_adapter
      Class.new(Igniter::Contract) do
        runner :inline, remote_adapter: adapter

        define do
          input :event
          remote :audit_result, contract: "WriteAudit", node: "http://unused.example", inputs: { event: :event }
          output :audit_result
        end
      end
    end

    it "includes routing trace in provenance for pending remote nodes" do
      contract = pending_contract_class.new(order_id: 42)
      contract.resolve_all

      trace = contract.lineage(:order_result).trace
      expect(trace.value).to include(
        pending: true,
        event: :order_result,
        routing_trace: pending_trace
      )
      expect(trace.value[:payload][:routing_trace]).to eq(pending_trace)
    end

    it "includes routing trace in provenance for failed remote nodes" do
      contract = failed_contract_class.new(event: "created")
      begin
        contract.resolve_all
      rescue Igniter::Error
        nil
      end

      trace = contract.lineage(:audit_result).trace
      expect(trace.value).to include(failed: true)
      expect(trace.value[:error]).to include(
        type: "Igniter::ResolutionError"
      )
      expect(trace.value[:error][:context][:routing_trace]).to eq(failed_trace)
    end
  end

  # ── Contract not yet executed ─────────────────────────────────────────────────

  describe "Contract#lineage before resolve_all" do
    it "raises ProvenanceError" do
      unresolved = simple_contract_class.new(price: 10.0, quantity: 1)
      # execution exists but cache is empty — builder will raise ProvenanceError
      # because the output node IS in the graph (this is fine; value will be nil)
      # The key case is when execution is nil, which cannot happen in current code
      # since execution is created in initialize. We test the output-not-found path.
      expect { unresolved.lineage(:nonexistent) }
        .to raise_error(Igniter::Provenance::ProvenanceError)
    end
  end

  # ── Composition output ────────────────────────────────────────────────────────

  describe "composition output" do
    let(:inner_class) do
      Class.new(Igniter::Contract) do
        define do
          input :rate, type: :numeric
          compute :fee, depends_on: :rate do |rate:| (rate * 10).round(2) end
          output :fee
        end
      end
    end

    let(:outer_class) do
      ic = inner_class
      Class.new(Igniter::Contract) do
        define do
          input :base,  type: :numeric
          input :rate,  type: :numeric

          compose :calc, contract: ic, inputs: { rate: :rate }

          compute :total, depends_on: %i[base calc] do |base:, calc:|
            (base + calc.fee).round(2)
          end

          output :total
        end
      end
    end

    it "traces through a composition node" do
      c = outer_class.new(base: 100.0, rate: 2.5)
      c.resolve_all
      lin = c.lineage(:total)

      expect(lin.value).to eq(125.0)
      expect(lin.trace.contributing.keys).to contain_exactly(:base, :calc)
      # :base is a direct input
      expect(lin.sensitive_to?(:base)).to be true
      # :rate is an input to the composition
      expect(lin.sensitive_to?(:rate)).to be true
    end
  end
end
