# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Distributed Contracts" do
  let(:store) { Igniter::Runtime::Stores::MemoryStore.new }

  let(:workflow_class) do
    Class.new(Igniter::Contract) do
      correlate_by :request_id, :company_id

      define do
        input :request_id
        input :company_id

        await :crm_data, event: :crm_webhook_received
        await :billing_data, event: :billing_data_fetched

        compute :report, with: %i[crm_data billing_data] do |crm_data:, billing_data:|
          { crm: crm_data, billing: billing_data }
        end

        output :report
      end
    end
  end

  describe ".correlate_by" do
    it "sets correlation keys on the class" do
      expect(workflow_class.correlation_keys).to eq(%i[request_id company_id])
    end
  end

  describe "compiled graph" do
    it "includes await nodes" do
      await_nodes = workflow_class.compiled_graph.await_nodes
      expect(await_nodes.map(&:name)).to contain_exactly(:crm_data, :billing_data)
      expect(await_nodes.map(&:event_name)).to contain_exactly(:crm_webhook_received, :billing_data_fetched)
    end

    it "await nodes have :await kind" do
      workflow_class.compiled_graph.await_nodes.each do |node|
        expect(node.kind).to eq(:await)
      end
    end
  end

  describe "execution with await nodes" do
    it "enters pending state when await nodes are unresolved" do
      instance = workflow_class.new(
        { request_id: "req-1", company_id: "co-1" },
        runner: :store,
        store: store
      )
      instance.resolve_all
      expect(instance.pending?).to be true
    end

    it "succeeds after all await nodes are resumed" do
      instance = workflow_class.new(
        { request_id: "req-1", company_id: "co-1" },
        runner: :store,
        store: store
      )
      instance.resolve_all

      instance.execution.resume(:crm_data, value: { name: "Acme" })
      instance.execution.resume(:billing_data, value: { plan: "pro" })
      instance.resolve_all

      expect(instance.success?).to be true
      expect(instance.result.report).to eq({ crm: { name: "Acme" }, billing: { plan: "pro" } })
    end
  end

  describe ".start" do
    it "returns a pending execution" do
      execution = workflow_class.start(
        { request_id: "req-1", company_id: "co-1" },
        store: store
      )
      expect(execution.pending?).to be true
    end

    it "saves the execution to the store with correlation" do
      workflow_class.start({ request_id: "req-1", company_id: "co-1" }, store: store)
      execution_id = store.find_by_correlation(
        graph: workflow_class.compiled_graph.name,
        correlation: { request_id: "req-1", company_id: "co-1" }
      )
      expect(execution_id).not_to be_nil
    end
  end

  describe ".deliver_event" do
    it "resumes the matching await node" do
      workflow_class.start({ request_id: "req-1", company_id: "co-1" }, store: store)

      execution = workflow_class.deliver_event(
        :crm_webhook_received,
        correlation: { request_id: "req-1", company_id: "co-1" },
        payload: { name: "Acme" },
        store: store
      )

      expect(execution.pending?).to be true
    end

    it "resolves after both events delivered" do
      workflow_class.start({ request_id: "req-2", company_id: "co-2" }, store: store)

      workflow_class.deliver_event(
        :crm_webhook_received,
        correlation: { request_id: "req-2", company_id: "co-2" },
        payload: { name: "Beta Corp" },
        store: store
      )

      execution = workflow_class.deliver_event(
        :billing_data_fetched,
        correlation: { request_id: "req-2", company_id: "co-2" },
        payload: { plan: "enterprise", mrr: 2000 },
        store: store
      )

      expect(execution.success?).to be true
      expect(execution.result.report[:crm]).to eq({ name: "Beta Corp" })
      expect(execution.result.report[:billing]).to eq({ plan: "enterprise", mrr: 2000 })
    end

    it "raises if no execution found for correlation" do
      expect do
        workflow_class.deliver_event(
          :crm_webhook_received,
          correlation: { request_id: "nonexistent", company_id: "none" },
          payload: {},
          store: store
        )
      end.to raise_error(Igniter::ResolutionError, /No pending execution found/)
    end

    it "raises if event name does not match any await node" do
      workflow_class.start({ request_id: "req-3", company_id: "co-3" }, store: store)

      expect do
        workflow_class.deliver_event(
          :unknown_event,
          correlation: { request_id: "req-3", company_id: "co-3" },
          payload: {},
          store: store
        )
      end.to raise_error(Igniter::ResolutionError, /No await node found/)
    end
  end

  describe "AwaitValidator" do
    it "raises ValidationError when correlation key is not declared as input" do
      expect do
        Class.new(Igniter::Contract) do
          correlate_by :request_id, :missing_input

          define do
            input :request_id

            await :crm_data, event: :crm_received
            output :crm_data, from: :crm_data
          end
        end
      end.to raise_error(Igniter::ValidationError, /missing_input/)
    end

    it "raises ValidationError when duplicate event names are used" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :id

            await :event_a, event: :same_event
            await :event_b, event: :same_event
            output :event_a, from: :event_a
          end
        end
      end.to raise_error(Igniter::ValidationError, /same_event/)
    end
  end

  describe "MemoryStore query API" do
    it "find_by_correlation returns execution_id" do
      store.save({ execution_id: "exec-1", states: {} }, correlation: { foo: "bar" }, graph: "TestGraph")
      result = store.find_by_correlation(graph: "TestGraph", correlation: { foo: "bar" })
      expect(result).to eq("exec-1")
    end

    it "find_by_correlation returns nil when not found" do
      result = store.find_by_correlation(graph: "TestGraph", correlation: { foo: "nope" })
      expect(result).to be_nil
    end

    it "list_all returns all execution ids" do
      store.save({ execution_id: "exec-1", states: {} })
      store.save({ execution_id: "exec-2", states: {} })
      expect(store.list_all).to include("exec-1", "exec-2")
    end

    it "list_all filters by graph" do
      store.save({ execution_id: "exec-1", states: {} }, graph: "Graph1", correlation: {})
      store.save({ execution_id: "exec-2", states: {} }, graph: "Graph2", correlation: {})
      expect(store.list_all(graph: "Graph1")).to eq(["exec-1"])
    end

    it "list_pending returns only executions with pending states" do
      store.save({ execution_id: "exec-pending", states: { crm: { status: "pending" } } })
      store.save({ execution_id: "exec-done", states: { crm: { status: "succeeded" } } })
      expect(store.list_pending).to include("exec-pending")
      expect(store.list_pending).not_to include("exec-done")
    end
  end
end
