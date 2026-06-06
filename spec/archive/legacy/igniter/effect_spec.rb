# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/saga"
require "igniter/extensions/execution_report"

RSpec.describe "Igniter Effect system" do
  # ── Test adapters ─────────────────────────────────────────────────────────

  let(:captured_calls) { [] }

  let(:db_adapter) do
    calls = captured_calls
    Class.new(Igniter::Effect) do
      effect_type :database
      idempotent  false

      define_method(:call) do |user_id:|
        calls << { user_id: user_id }
        { id: user_id, name: "Alice" }
      end
    end
  end

  let(:http_adapter) do
    Class.new(Igniter::Effect) do
      effect_type :http

      def call(user:)
        { status: "notified", recipient: user[:name] }
      end
    end
  end

  let(:failing_adapter) do
    Class.new(Igniter::Effect) do
      effect_type :database

      def call(**)
        raise "DB connection failed"
      end
    end
  end

  let(:simple_contract) do
    adapter = db_adapter
    Class.new(Igniter::Contract) do
      define do
        input  :user_id
        effect :user_data, uses: adapter, depends_on: :user_id
        output :user_data
      end
    end
  end

  # ── Igniter::Effect base class ────────────────────────────────────────────

  describe "Igniter::Effect" do
    it "is a subclass of Igniter::Executor" do
      expect(Igniter::Effect.ancestors).to include(Igniter::Executor)
    end

    describe ".effect_type" do
      it "defaults to :generic" do
        klass = Class.new(Igniter::Effect)
        expect(klass.effect_type).to eq(:generic)
      end

      it "can be set with a symbol" do
        klass = Class.new(Igniter::Effect) { effect_type :database }
        expect(klass.effect_type).to eq(:database)
      end

      it "converts string to symbol" do
        klass = Class.new(Igniter::Effect) { effect_type "http" }
        expect(klass.effect_type).to eq(:http)
      end

      it "is inherited by subclasses" do
        parent = Class.new(Igniter::Effect) { effect_type :cache }
        child  = Class.new(parent)
        expect(child.effect_type).to eq(:cache)
      end

      it "can be overridden in subclass without affecting parent" do
        parent = Class.new(Igniter::Effect) { effect_type :cache }
        child  = Class.new(parent) { effect_type :queue }
        expect(parent.effect_type).to eq(:cache)
        expect(child.effect_type).to eq(:queue)
      end
    end

    describe ".idempotent" do
      it "defaults to false" do
        klass = Class.new(Igniter::Effect)
        expect(klass.idempotent?).to be(false)
      end

      it "can be set to true" do
        klass = Class.new(Igniter::Effect) { idempotent true }
        expect(klass.idempotent?).to be(true)
      end

      it "shorthand: idempotent without argument defaults to true" do
        klass = Class.new(Igniter::Effect) { idempotent }
        expect(klass.idempotent?).to be(true)
      end

      it "is inherited by subclasses" do
        parent = Class.new(Igniter::Effect) { idempotent true }
        child  = Class.new(parent)
        expect(child.idempotent?).to be(true)
      end
    end

    describe ".compensate / .built_in_compensation" do
      it "is nil by default" do
        klass = Class.new(Igniter::Effect)
        expect(klass.built_in_compensation).to be_nil
      end

      it "stores the provided block" do
        klass = Class.new(Igniter::Effect) do
          compensate do |**|
            "rolled back"
          end
        end
        expect(klass.built_in_compensation).to be_a(Proc)
      end

      it "raises ArgumentError when called without a block" do
        klass = Class.new(Igniter::Effect)
        expect { klass.compensate }.to raise_error(ArgumentError, /requires a block/)
      end

      it "is inherited by subclasses" do
        block  = proc { |**| "undo" }
        parent = Class.new(Igniter::Effect) { compensate(&block) }
        child  = Class.new(parent)
        expect(child.built_in_compensation).to be(block)
      end

      it "can be overridden in subclass without affecting parent" do
        parent_block = proc { |**| "parent undo" }
        child_block  = proc { |**| "child undo" }
        parent = Class.new(Igniter::Effect) { compensate(&parent_block) }
        child  = Class.new(parent) { compensate(&child_block) }
        expect(parent.built_in_compensation).to be(parent_block)
        expect(child.built_in_compensation).to be(child_block)
      end
    end
  end

  # ── EffectNode model ──────────────────────────────────────────────────────

  describe "Igniter::Model::EffectNode" do
    let(:node) do
      Igniter::Model::EffectNode.new(
        id: "test:1",
        name: :user_data,
        dependencies: [:user_id],
        adapter_class: db_adapter
      )
    end

    it "has kind :effect" do
      expect(node.kind).to eq(:effect)
    end

    it "delegates effect_type to adapter_class" do
      expect(node.effect_type).to eq(:database)
    end

    it "delegates idempotent? to adapter_class" do
      expect(node.idempotent?).to be(false)
    end

    it "stores adapter_class" do
      expect(node.adapter_class).to eq(db_adapter)
    end
  end

  # ── DSL: effect keyword ───────────────────────────────────────────────────

  describe "DSL: effect keyword" do
    context "with uses: AdapterClass" do
      it "creates a contract that resolves the effect" do
        contract = simple_contract.new(user_id: "u1")
        contract.resolve_all

        expect(contract.result.user_data).to eq({ id: "u1", name: "Alice" })
      end

      it "passes resolved dependencies to adapter#call" do
        simple_contract.new(user_id: "u42").resolve_all
        expect(captured_calls).to eq([{ user_id: "u42" }])
      end

      it "creates an EffectNode in the compiled graph" do
        graph = simple_contract.compiled_graph
        effect_nodes = graph.nodes.select { |n| n.kind == :effect }
        expect(effect_nodes.length).to eq(1)
        expect(effect_nodes.first.name).to eq(:user_data)
      end

      it "raises CompileError when class is not an Igniter::Effect subclass" do
        not_an_effect = Class.new
        expect do
          Class.new(Igniter::Contract) do
            define do
              input  :x
              effect :result, uses: not_an_effect, depends_on: :x
            end
          end
        end.to raise_error(Igniter::CompileError, /must be an Igniter::Effect subclass/)
      end
    end

    context "with uses: :registry_symbol" do
      before do
        Igniter.effect_registry.clear
        Igniter.register_effect(:test_db, db_adapter)
      end

      after do
        Igniter.effect_registry.clear
      end

      it "resolves adapter from the registry" do
        contract_class = Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :user_data, uses: :test_db, depends_on: :user_id
            output :user_data
          end
        end

        contract = contract_class.new(user_id: "u1")
        contract.resolve_all
        expect(contract.result.user_data).to eq({ id: "u1", name: "Alice" })
      end

      it "raises KeyError for unregistered name" do
        expect do
          Class.new(Igniter::Contract) do
            define do
              input  :user_id
              effect :user_data, uses: :unknown_effect, depends_on: :user_id
            end
          end
        end.to raise_error(KeyError, /unknown_effect.*not registered/)
      end
    end

    context "dependency chain" do
      it "resolves effect that depends on another effect" do
        adapter_a = db_adapter
        adapter_b = http_adapter

        contract_class = Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :user,     uses: adapter_a, depends_on: :user_id
            effect :notified, uses: adapter_b, depends_on: :user
            output :notified
          end
        end

        contract = contract_class.new(user_id: "u1")
        contract.resolve_all
        expect(contract.result.notified).to eq({ status: "notified", recipient: "Alice" })
      end
    end

    context "effect failure" do
      let(:failing_contract) do
        adapter = failing_adapter
        Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :user_data, uses: adapter, depends_on: :user_id
            output :user_data
          end
        end
      end

      it "propagates the error as a ResolutionError" do
        contract = failing_contract.new(user_id: "u1")
        expect { contract.resolve_all }.to raise_error(Igniter::ResolutionError, /DB connection failed/)
      end
    end
  end

  # ── EffectRegistry ────────────────────────────────────────────────────────

  describe "Igniter::EffectRegistry" do
    let(:registry) { Igniter::EffectRegistry.new }

    describe "#register" do
      it "registers an Effect subclass" do
        registry.register(:test, db_adapter)
        expect(registry.registered?(:test)).to be(true)
      end

      it "accepts string keys (converts to symbol)" do
        registry.register("test_key", db_adapter)
        expect(registry.registered?(:test_key)).to be(true)
      end

      it "raises ArgumentError for non-Effect classes" do
        expect do
          registry.register(:bad, Class.new)
        end.to raise_error(ArgumentError, /must be a subclass of Igniter::Effect/)
      end

      it "returns self for chaining" do
        result = registry.register(:test, db_adapter)
        expect(result).to be(registry)
      end
    end

    describe "#fetch" do
      before { registry.register(:db, db_adapter) }

      it "returns the Registration" do
        reg = registry.fetch(:db)
        expect(reg.adapter_class).to eq(db_adapter)
        expect(reg.key).to eq(:db)
      end

      it "raises KeyError for unknown key" do
        expect { registry.fetch(:unknown) }.to raise_error(KeyError, /unknown.*not registered/)
      end
    end

    describe "#registered?" do
      it "returns false when not registered" do
        expect(registry.registered?(:nope)).to be(false)
      end

      it "returns true when registered" do
        registry.register(:yes, db_adapter)
        expect(registry.registered?(:yes)).to be(true)
      end
    end

    describe "#all" do
      it "returns all registrations" do
        registry.register(:db, db_adapter)
        registry.register(:http, http_adapter)
        expect(registry.all.map(&:key)).to contain_exactly(:db, :http)
      end
    end

    describe "#size" do
      it "returns the number of registered effects" do
        registry.register(:db, db_adapter)
        expect(registry.size).to eq(1)
      end
    end

    describe "#clear" do
      it "removes all registrations" do
        registry.register(:db, db_adapter)
        registry.clear
        expect(registry.size).to eq(0)
      end
    end
  end

  # ── execution_report integration ──────────────────────────────────────────

  describe "execution_report integration" do
    it "includes effect nodes in the report" do
      contract = simple_contract.new(user_id: "u1")
      contract.resolve_all
      report = contract.execution_report

      effect_entries = report.entries.select { |e| e.kind == :effect }
      expect(effect_entries.length).to eq(1)
      expect(effect_entries.first.name).to eq(:user_data)
    end

    it "carries effect_type on the NodeEntry" do
      contract = simple_contract.new(user_id: "u1")
      contract.resolve_all
      report = contract.execution_report

      entry = report.entries.find { |e| e.name == :user_data }
      expect(entry.effect_type).to eq(:database)
    end

    it "formats effect_type in the explain output" do
      contract = simple_contract.new(user_id: "u1")
      contract.resolve_all

      output = contract.execution_report.explain
      expect(output).to include("effect:database")
    end

    it "shows [ok] for a succeeded effect" do
      contract = simple_contract.new(user_id: "u1")
      contract.resolve_all
      output = contract.execution_report.explain
      expect(output).to match(/\[ok\].*user_data/)
    end

    it "shows [fail] for a failed effect" do
      adapter = failing_adapter
      contract_class = Class.new(Igniter::Contract) do
        define do
          input  :user_id
          effect :bad_effect, uses: adapter, depends_on: :user_id
          output :bad_effect
        end
      end

      contract = contract_class.new(user_id: "u1")
      begin
        contract.resolve_all
      rescue Igniter::Error
        nil
      end

      output = contract.execution_report.explain
      expect(output).to match(/\[fail\].*bad_effect/)
    end
  end

  # ── saga integration ──────────────────────────────────────────────────────

  describe "saga integration" do
    describe "built-in compensation on Effect class" do
      let(:rollback_log) { [] }

      let(:compensating_adapter) do
        log = rollback_log
        Class.new(Igniter::Effect) do
          effect_type :database

          def call(user_id:)
            { id: user_id, name: "Alice" }
          end

          compensate do |value:, **|
            log << { undone: value[:id] }
          end
        end
      end

      let(:always_fail_adapter) do
        Class.new(Igniter::Effect) do
          effect_type :notification

          def call(**)
            raise "Notification service unavailable"
          end
        end
      end

      let(:saga_contract_class) do
        db  = compensating_adapter
        ntf = always_fail_adapter

        Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :user,   uses: db,  depends_on: :user_id
            effect :notify, uses: ntf, depends_on: :user
            output :notify
          end
        end
      end

      it "runs built-in compensation when a downstream node fails" do
        result = saga_contract_class.new(user_id: "u1").resolve_saga

        expect(result.failed?).to be(true)
        expect(rollback_log).to eq([{ undone: "u1" }])
      end

      it "records the built-in compensation in result.compensations" do
        result = saga_contract_class.new(user_id: "u1").resolve_saga

        names = result.compensations.map(&:node_name)
        expect(names).to include(:user)
      end

      it "marks the compensation record as successful" do
        result = saga_contract_class.new(user_id: "u1").resolve_saga

        record = result.compensations.find { |r| r.node_name == :user }
        expect(record.success?).to be(true)
      end
    end

    describe "contract-level compensate overrides built-in" do
      let(:built_in_log)  { [] }
      let(:override_log)  { [] }

      let(:effect_with_built_in) do
        log = built_in_log
        Class.new(Igniter::Effect) do
          effect_type :database

          def call(user_id:)
            { id: user_id }
          end

          compensate do |**|
            log << :built_in
          end
        end
      end

      let(:always_fail) do
        Class.new(Igniter::Effect) do
          def call(**)
            raise "downstream failure"
          end
        end
      end

      it "uses the contract-level block instead of the built-in one" do
        db  = effect_with_built_in
        ntf = always_fail
        log = override_log

        contract_class = Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :user,   uses: db,  depends_on: :user_id
            effect :notify, uses: ntf, depends_on: :user
            output :notify
          end

          compensate(:user) do |**|
            log << :override
          end
        end

        contract_class.new(user_id: "u1").resolve_saga

        expect(override_log).to eq([:override])
        expect(built_in_log).to be_empty
      end
    end

    describe "saga with no compensations" do
      it "returns empty compensations array when nothing is declared" do
        adapter = db_adapter
        contract_class = Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :user_data, uses: adapter, depends_on: :user_id
            output :user_data
          end
        end

        result = contract_class.new(user_id: "u1").resolve_saga
        expect(result.success?).to be(true)
        expect(result.compensations).to be_empty
      end
    end
  end

  # ── compiler validation ───────────────────────────────────────────────────

  describe "compiler validation" do
    it "raises ValidationError for non-keyword call parameters" do
      bad_adapter = Class.new(Igniter::Effect) do
        # positional parameter — intentional to trigger validation error
        def call(user_id)
          user_id
        end
      end

      expect do
        Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :data, uses: bad_adapter, depends_on: :user_id
            output :data
          end
        end
      end.to raise_error(Igniter::ValidationError, /positional parameters/)
    end

    it "raises ValidationError when required keyword is undeclared dependency" do
      strict_adapter = Class.new(Igniter::Effect) do
        def call(user_id:, account_id:) # rubocop:disable Lint/UnusedMethodArgument
          {}
        end
      end

      expect do
        Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :data, uses: strict_adapter, depends_on: :user_id
            output :data
            # account_id is required by call but not a dependency
          end
        end
      end.to raise_error(Igniter::ValidationError, /account_id/)
    end

    it "raises ValidationError for unknown dependency" do
      expect do
        adapter = db_adapter
        Class.new(Igniter::Contract) do
          define do
            input  :user_id
            effect :data, uses: adapter, depends_on: :nonexistent_dep
            output :data
          end
        end
      end.to raise_error(Igniter::ValidationError, /Unknown dependency.*nonexistent_dep/)
    end
  end

  # ── Igniter.effect_registry global API ───────────────────────────────────

  describe "Igniter.effect_registry" do
    after { Igniter.effect_registry.clear }

    it "returns the global EffectRegistry" do
      expect(Igniter.effect_registry).to be_a(Igniter::EffectRegistry)
    end

    it "returns the same instance on repeated calls" do
      expect(Igniter.effect_registry).to be(Igniter.effect_registry)
    end
  end

  describe "Igniter.register_effect" do
    after { Igniter.effect_registry.clear }

    it "registers an effect in the global registry" do
      Igniter.register_effect(:global_db, db_adapter)
      expect(Igniter.effect_registry.registered?(:global_db)).to be(true)
    end
  end
end
