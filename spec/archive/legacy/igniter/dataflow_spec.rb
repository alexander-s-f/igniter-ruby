# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/dataflow"

RSpec.describe "Igniter::Dataflow — incremental collection" do
  # ─── Shared child contract ────────────────────────────────────────────────

  let(:child_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :sensor_id
        input :value, type: :numeric
        compute :status, depends_on: :value do |value:|
          value > 50 ? :alert : :normal
        end
        output :status
      end
    end
  end

  let(:call_tracker) { [] }

  # Child contract that records every call so we can assert re-run counts.
  let(:tracked_child) do
    tracker = call_tracker
    Class.new(Igniter::Contract) do
      define do
        input :sensor_id
        input :value, type: :numeric
        compute :status, depends_on: :value do |value:|
          tracker << :called
          value > 50 ? :alert : :normal
        end
        output :status
      end
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  def make_contract(each:, window: nil) # rubocop:disable Metrics/MethodLength
    klass = each
    Class.new(Igniter::Contract) do
      define do
        input :readings, type: :array
        collection :processed,
                   with: :readings,
                   each: klass,
                   key: :sensor_id,
                   mode: :incremental,
                   window: window
        output :processed
      end
    end
  end

  let(:sensors) do
    [
      { sensor_id: "s1", value: 30 },
      { sensor_id: "s2", value: 70 }
    ]
  end

  # ─── Basic incremental semantics ──────────────────────────────────────────

  describe "first resolve — treats all items as :added" do
    it "adds every item on the first call" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.added).to match_array(%w[s1 s2])
      expect(diff.removed).to be_empty
      expect(diff.changed).to be_empty
      expect(diff.unchanged).to be_empty
    end

    it "resolves all items' child contracts" do
      contract = make_contract(each: tracked_child).new(readings: sensors)
      contract.resolve_all
      expect(call_tracker.size).to eq(2)
    end
  end

  describe "second resolve with identical items" do
    it "marks all items as :unchanged" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.update_inputs(readings: sensors.dup)
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.unchanged).to match_array(%w[s1 s2])
      expect(diff.added).to be_empty
      expect(diff.changed).to be_empty
    end

    it "does not re-run child contracts" do
      contract = make_contract(each: tracked_child).new(readings: sensors)
      contract.resolve_all
      call_tracker.clear
      contract.update_inputs(readings: sensors.dup)
      contract.resolve_all
      expect(call_tracker).to be_empty
    end
  end

  describe "one item changed" do
    let(:updated_sensors) do
      [
        { sensor_id: "s1", value: 99 }, # changed: value 30 → 99
        { sensor_id: "s2", value: 70 }  # unchanged
      ]
    end

    it "marks only the changed item" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.update_inputs(readings: updated_sensors)
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.changed).to eq(["s1"])
      expect(diff.unchanged).to eq(["s2"])
      expect(diff.added).to be_empty
    end

    it "re-runs only the changed item's child contract" do
      contract = make_contract(each: tracked_child).new(readings: sensors)
      contract.resolve_all
      call_tracker.clear
      contract.update_inputs(readings: updated_sensors)
      contract.resolve_all
      expect(call_tracker.size).to eq(1) # only s1 re-run
    end

    it "updates the resolved status in the result" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.update_inputs(readings: updated_sensors)
      contract.resolve_all
      result = contract.result.processed
      expect(result["s1"].result.status).to eq(:alert)
      expect(result["s2"].result.status).to eq(:alert) # unchanged (value=70 → alert)
    end
  end

  describe "item added" do
    let(:extended_sensors) { sensors + [{ sensor_id: "s3", value: 10 }] }

    it "marks the new item as :added" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.update_inputs(readings: extended_sensors)
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.added).to eq(["s3"])
      expect(diff.unchanged).to match_array(%w[s1 s2])
    end

    it "re-runs only the new item" do
      contract = make_contract(each: tracked_child).new(readings: sensors)
      contract.resolve_all
      call_tracker.clear
      contract.update_inputs(readings: extended_sensors)
      contract.resolve_all
      expect(call_tracker.size).to eq(1)
    end
  end

  describe "item removed" do
    let(:reduced_sensors) { [{ sensor_id: "s1", value: 30 }] }

    it "marks the missing item as :removed" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.update_inputs(readings: reduced_sensors)
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.removed).to eq(["s2"])
      expect(diff.unchanged).to eq(["s1"])
    end

    it "excludes the removed item from the result" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.update_inputs(readings: reduced_sensors)
      contract.resolve_all
      expect(contract.result.processed.keys).to eq(["s1"])
    end
  end

  # ─── Result structure ──────────────────────────────────────────────────────

  describe "IncrementalCollectionResult" do
    it "responds to .diff" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      expect(contract.result.processed).to respond_to(:diff)
    end

    it "includes diff counters in summary" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      summary = contract.result.processed.summary
      expect(summary).to include(:added, :removed, :changed, :unchanged)
    end

    it "preserves input array ordering in the result keys" do
      ordered = [
        { sensor_id: "c", value: 10 },
        { sensor_id: "a", value: 20 },
        { sensor_id: "b", value: 30 }
      ]
      contract = make_contract(each: child_contract).new(readings: ordered)
      contract.resolve_all
      expect(contract.result.processed.keys).to eq(%w[c a b])
    end
  end

  # ─── Diff object ──────────────────────────────────────────────────────────

  describe Igniter::Dataflow::Diff do
    let(:diff) { described_class.new(added: ["x"], removed: [], changed: ["y"], unchanged: ["z"]) }

    it "#any_changes? returns true when there are additions or changes" do
      expect(diff.any_changes?).to be true
    end

    it "#any_changes? returns false when only unchanged" do
      empty_diff = described_class.new(added: [], removed: [], changed: [], unchanged: ["z"])
      expect(empty_diff.any_changes?).to be false
    end

    it "#processed_count equals added + changed" do
      expect(diff.processed_count).to eq(2)
    end

    it "#explain returns a readable string" do
      expect(diff.explain).to include("added").and include("changed")
    end

    it "#explain returns '(no changes)' when empty" do
      empty_diff = described_class.new(added: [], removed: [], changed: [], unchanged: [])
      expect(empty_diff.explain).to eq("(no changes)")
    end
  end

  # ─── Sliding window ───────────────────────────────────────────────────────

  describe "window: { last: N }" do
    let(:many_sensors) do
      (1..5).map { |i| { sensor_id: "s#{i}", value: i * 10 } }
    end

    it "includes only the last N items in each resolve" do
      contract = make_contract(each: child_contract, window: { last: 2 }).new(readings: many_sensors)
      contract.resolve_all
      expect(contract.result.processed.keys).to match_array(%w[s4 s5])
    end

    it "only re-runs child contracts for items inside the window" do
      contract = make_contract(each: tracked_child, window: { last: 2 }).new(readings: many_sensors)
      contract.resolve_all
      expect(call_tracker.size).to eq(2)
    end
  end

  describe "window: { seconds: N, field: :ts }" do
    it "includes only items within the time window" do
      # Child contract that also accepts the :ts timestamp field
      ts_child = Class.new(Igniter::Contract) do
        define do
          input :sensor_id
          input :value, type: :numeric
          input :ts
          compute :status, depends_on: :value do |value:|
            value > 50 ? :alert : :normal
          end
          output :status
        end
      end

      now = Time.now
      events = [
        { sensor_id: "old",   value: 1, ts: now - 120 }, # outside 60s window
        { sensor_id: "fresh", value: 2, ts: now - 10  }  # inside
      ]
      contract = make_contract(each: ts_child, window: { seconds: 60, field: :ts }).new(readings: events)
      contract.resolve_all
      expect(contract.result.processed.keys).to eq(["fresh"])
    end
  end

  # ─── feed_diff convenience ────────────────────────────────────────────────

  describe "#feed_diff" do
    it "adds new items" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.feed_diff(:readings, add: [{ sensor_id: "s3", value: 5 }])
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.added).to eq(["s3"])
    end

    it "removes items by key" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.feed_diff(:readings, remove: ["s2"])
      contract.resolve_all
      expect(contract.result.processed.keys).to eq(["s1"])
    end

    it "removes items by full Hash (key extracted automatically)" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.feed_diff(:readings, remove: [{ sensor_id: "s1", value: 30 }])
      contract.resolve_all
      expect(contract.result.processed.keys).to eq(["s2"])
    end

    it "updates an existing item" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      contract.feed_diff(:readings, update: [{ sensor_id: "s1", value: 99 }])
      contract.resolve_all
      diff = contract.collection_diff(:processed)
      expect(diff.changed).to eq(["s1"])
      expect(contract.result.processed["s1"].result.status).to eq(:alert)
    end

    it "raises ArgumentError when no incremental collection uses the input" do
      contract = make_contract(each: child_contract).new(readings: sensors)
      contract.resolve_all
      expect { contract.feed_diff(:nonexistent, add: []) }.to raise_error(ArgumentError, /No incremental collection/)
    end
  end

  # ─── Compiler validation ──────────────────────────────────────────────────

  describe "compiler validation" do
    it "accepts mode: :incremental without error" do
      klass = child_contract
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :items, type: :array
            collection :results, with: :items, each: klass, key: :sensor_id, mode: :incremental
            output :results
          end
        end
      end.not_to raise_error
    end

    it "rejects unknown modes" do
      klass = child_contract
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :items, type: :array
            collection :results, with: :items, each: klass, key: :sensor_id, mode: :bogus
            output :results
          end
        end
      end.to raise_error(Igniter::CompileError, /mode must be/)
    end

    it "rejects invalid window: (missing :last or :seconds)" do
      klass = child_contract
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :items, type: :array
            collection :results, with: :items, each: klass, key: :sensor_id, mode: :incremental, window: { bogus: 1 }
            output :results
          end
        end
      end.to raise_error(Igniter::CompileError, /window: must use :last or :seconds/)
    end

    it "rejects window: { seconds: } without :field" do
      klass = child_contract
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :items, type: :array
            collection :results, with: :items, each: klass, key: :sensor_id, mode: :incremental, window: { seconds: 60 }
            output :results
          end
        end
      end.to raise_error(Igniter::CompileError, /requires a :field key/)
    end
  end

  # ─── Load guard ───────────────────────────────────────────────────────────

  describe "load guard" do
    it "emits a ResolutionError when dataflow is used without being required" do
      klass = child_contract
      contract_class = Class.new(Igniter::Contract) do
        define do
          input :items, type: :array
          collection :results, with: :items, each: klass, key: :sensor_id, mode: :incremental
          output :results
        end
      end

      contract = contract_class.new(items: [{ sensor_id: "x", value: 1 }])

      # Temporarily hide the Dataflow constant to simulate the extension not being loaded.
      dataflow_backup = Igniter::Dataflow
      Igniter.send(:remove_const, :Dataflow)
      begin
        pattern = %r{require 'igniter/extensions/dataflow'}
        expect { contract.resolve_all }.to raise_error(Igniter::ResolutionError, pattern)
      ensure
        Igniter::Dataflow = dataflow_backup # rubocop:disable Naming/ConstantName
      end
    end
  end

  # ─── Zero impact on existing modes ────────────────────────────────────────

  describe "existing :collect mode is unaffected" do
    it "still works when dataflow is loaded" do
      klass = child_contract
      contract_class = Class.new(Igniter::Contract) do
        define do
          input :items, type: :array
          collection :results, with: :items, each: klass, key: :sensor_id, mode: :collect
          output :results
        end
      end

      contract = contract_class.new(items: [{ sensor_id: "x", value: 10 }])
      contract.resolve_all
      expect(contract.result.results["x"].result.status).to eq(:normal)
    end
  end
end
