# frozen_string_literal: true

require "spec_helper"
require "igniter/extensions/dataflow"

RSpec.describe "Incremental Dataflow — Maintained Aggregates" do
  # ── Shared fixtures ──────────────────────────────────────────────────────────

  let(:child_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :sensor_id
        input :value, type: :numeric
        input :zone, default: "default"
        compute :status, depends_on: :value do |value:|
          value > 50 ? :critical : :normal
        end
        output :status
        output :value   # pass-through for aggregation projections
        output :zone
      end
    end
  end

  # Builds a contract class with an incremental collection + custom define block
  def make_pipeline(klass, &block) # rubocop:disable Metrics/MethodLength
    Class.new(Igniter::Contract) do
      define do
        input :sensors, type: :array
        collection :processed,
                   with: :sensors, each: klass,
                   key: :sensor_id, mode: :incremental
        output :processed
        instance_exec(&block) if block
      end
    end
  end

  def sensor(id, value, zone: "A")
    { sensor_id: id, value: value, zone: zone }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # count operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe ":count aggregate" do
    context "with no filter (count all)" do
      let(:pipeline) do
        make_pipeline(child_contract) do
          aggregate :total, from: :processed
          output :total
        end
      end

      it "counts all items on first resolve" do
        c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70), sensor("s3", 80)])
        c.resolve_all
        expect(c.result.total).to eq(3)
      end

      it "increments when item added" do
        c = pipeline.new(sensors: [sensor("s1", 10)])
        c.resolve_all
        c.feed_diff(:sensors, add: [sensor("s2", 70)])
        c.resolve_all
        expect(c.result.total).to eq(2)
      end

      it "decrements when item removed" do
        c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70)])
        c.resolve_all
        c.feed_diff(:sensors, remove: ["s1"])
        c.resolve_all
        expect(c.result.total).to eq(1)
      end

      it "stays stable when item changed" do
        c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70)])
        c.resolve_all
        c.feed_diff(:sensors, update: [sensor("s1", 99)])
        c.resolve_all
        expect(c.result.total).to eq(2)
      end

      it "stays stable when nothing changes" do
        c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70)])
        c.resolve_all
        c.update_inputs(sensors: c.execution.inputs[:sensors].dup)
        c.resolve_all
        expect(c.result.total).to eq(2)
      end
    end

    context "with filter" do
      let(:pipeline) do
        make_pipeline(child_contract) do
          aggregate :alerts, from: :processed, count: ->(item) { item.result.status == :critical }
          output :alerts
        end
      end

      it "counts only items matching filter" do
        c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70), sensor("s3", 80)])
        c.resolve_all
        expect(c.result.alerts).to eq(2)
      end

      it "decrements correctly when critical item is removed" do
        c = pipeline.new(sensors: [sensor("s1", 70), sensor("s2", 80)])
        c.resolve_all
        c.feed_diff(:sensors, remove: ["s1"])
        c.resolve_all
        expect(c.result.alerts).to eq(1)
      end

      it "retracts contribution when item drops below threshold" do
        c = pipeline.new(sensors: [sensor("s1", 70)])
        c.resolve_all
        expect(c.result.alerts).to eq(1)

        c.feed_diff(:sensors, update: [sensor("s1", 20)])  # critical → normal
        c.resolve_all
        expect(c.result.alerts).to eq(0)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # sum operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe ":sum aggregate" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :total_value, from: :processed, sum: ->(item) { item.result.value.to_f }
        output :total_value
      end
    end

    it "sums all values on first resolve" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 70)])
      c.resolve_all
      expect(c.result.total_value).to eq(100.0)
    end

    it "adds new item's value on add" do
      c = pipeline.new(sensors: [sensor("s1", 30)])
      c.resolve_all
      c.feed_diff(:sensors, add: [sensor("s2", 50)])
      c.resolve_all
      expect(c.result.total_value).to eq(80.0)
    end

    it "subtracts removed item's value correctly" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 70)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s1"])
      c.resolve_all
      expect(c.result.total_value).to eq(70.0)
    end

    it "applies old-retract + new-add when item changes" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 70)])
      c.resolve_all
      c.feed_diff(:sensors, update: [sensor("s1", 50)])  # 30 → 50, delta = +20
      c.resolve_all
      expect(c.result.total_value).to eq(120.0)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # avg operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe ":avg aggregate" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :avg_value, from: :processed, avg: ->(item) { item.result.value.to_f }
        output :avg_value
      end
    end

    it "returns correct mean on first resolve" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 70), sensor("s3", 50)])
      c.resolve_all
      expect(c.result.avg_value).to be_within(0.001).of(50.0)
    end

    it "returns 0.0 for empty collection" do
      c = pipeline.new(sensors: [sensor("s1", 30)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s1"])
      c.resolve_all
      expect(c.result.avg_value).to eq(0.0)
    end

    it "updates correctly after removal" do
      c = pipeline.new(sensors: [sensor("s1", 60), sensor("s2", 90)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s2"])
      c.resolve_all
      expect(c.result.avg_value).to be_within(0.001).of(60.0)
    end

    it "updates correctly after change" do
      c = pipeline.new(sensors: [sensor("s1", 40), sensor("s2", 80)])
      c.resolve_all
      c.feed_diff(:sensors, update: [sensor("s2", 20)])
      c.resolve_all
      expect(c.result.avg_value).to be_within(0.001).of(30.0)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # max operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe ":max aggregate" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :peak, from: :processed, max: ->(item) { item.result.value.to_f }
        output :peak
      end
    end

    it "returns max on first resolve" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 90), sensor("s3", 50)])
      c.resolve_all
      expect(c.result.peak).to eq(90.0)
    end

    it "re-computes max when current maximum is removed" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 90)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s2"])
      c.resolve_all
      expect(c.result.peak).to eq(30.0)
    end

    it "updates max when new higher value added" do
      c = pipeline.new(sensors: [sensor("s1", 30)])
      c.resolve_all
      c.feed_diff(:sensors, add: [sensor("s2", 99)])
      c.resolve_all
      expect(c.result.peak).to eq(99.0)
    end

    it "returns nil for empty collection" do
      c = pipeline.new(sensors: [sensor("s1", 30)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s1"])
      c.resolve_all
      expect(c.result.peak).to be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # min operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe ":min aggregate" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :floor, from: :processed, min: ->(item) { item.result.value.to_f }
        output :floor
      end
    end

    it "returns min on first resolve" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 10), sensor("s3", 50)])
      c.resolve_all
      expect(c.result.floor).to eq(10.0)
    end

    it "re-computes min when current minimum is removed" do
      c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 50)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s1"])
      c.resolve_all
      expect(c.result.floor).to eq(50.0)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # group_count operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe ":group_count aggregate" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :by_status, from: :processed, group_count: ->(item) { item.result.status }
        output :by_status
      end
    end

    it "groups by key on first resolve" do
      c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70), sensor("s3", 80)])
      c.resolve_all
      expect(c.result.by_status).to eq({ normal: 1, critical: 2 })
    end

    it "decrements group when item removed" do
      c = pipeline.new(sensors: [sensor("s1", 10), sensor("s2", 70)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s2"])
      c.resolve_all
      expect(c.result.by_status).to eq({ normal: 1 })
    end

    it "removes group key when count reaches zero" do
      c = pipeline.new(sensors: [sensor("s1", 70)])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s1"])
      c.resolve_all
      expect(c.result.by_status).to eq({})
    end

    it "moves item between groups when status changes" do
      c = pipeline.new(sensors: [sensor("s1", 70), sensor("s2", 80)])
      c.resolve_all
      c.feed_diff(:sensors, update: [sensor("s1", 10)])  # critical → normal
      c.resolve_all
      expect(c.result.by_status).to eq({ normal: 1, critical: 1 })
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # custom operator
  # ─────────────────────────────────────────────────────────────────────────────

  describe "custom aggregate" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :unique_zones, from: :processed,
                  initial: [],
                  add:    ->(acc, item) { (acc + [item.result.zone]).uniq },
                  remove: ->(acc, item) { acc - [item.result.zone] }
        output :unique_zones
      end
    end

    it "collects unique zones on first resolve" do
      c = pipeline.new(sensors: [
        sensor("s1", 10, zone: "A"),
        sensor("s2", 70, zone: "B"),
        sensor("s3", 80, zone: "A")
      ])
      c.resolve_all
      expect(c.result.unique_zones.sort).to eq(%w[A B])
    end

    it "removes zone when last sensor in that zone is removed" do
      c = pipeline.new(sensors: [sensor("s1", 10, zone: "A"), sensor("s2", 70, zone: "B")])
      c.resolve_all
      c.feed_diff(:sensors, remove: ["s2"])
      c.resolve_all
      expect(c.result.unique_zones).to eq(["A"])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Multiple aggregates in one contract
  # ─────────────────────────────────────────────────────────────────────────────

  describe "multiple aggregates" do
    let(:pipeline) do
      make_pipeline(child_contract) do
        aggregate :total,   from: :processed
        aggregate :alerts,  from: :processed, count: ->(item) { item.result.status == :critical }
        aggregate :avg_val, from: :processed, avg:   ->(item) { item.result.value.to_f }
        output :total
        output :alerts
        output :avg_val
      end
    end

    it "updates all aggregates independently on each round" do
      c = pipeline.new(sensors: [sensor("s1", 30), sensor("s2", 70), sensor("s3", 90)])
      c.resolve_all
      expect(c.result.total).to eq(3)
      expect(c.result.alerts).to eq(2)
      expect(c.result.avg_val).to be_within(0.01).of(63.33)

      # Remove s2 (critical), update s1 30→80 (now critical)
      c.feed_diff(:sensors, remove: ["s2"], update: [sensor("s1", 80)])
      c.resolve_all
      expect(c.result.total).to eq(2)
      expect(c.result.alerts).to eq(2)   # s1 + s3
      expect(c.result.avg_val).to be_within(0.01).of(85.0)  # (80+90)/2
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Compiler validation
  # ─────────────────────────────────────────────────────────────────────────────

  describe "compiler validation" do
    it "raises when source collection does not exist" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :items, type: :array
            aggregate :total, from: :nonexistent
            output :total
          end
        end
      end.to raise_error(Igniter::CompileError, /references unknown collection 'nonexistent'/)
    end

    it "raises when source is not a collection node" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :items, type: :array
            aggregate :total, from: :items
            output :total
          end
        end
      end.to raise_error(Igniter::CompileError, /must be a collection node/)
    end

    it "raises when source collection uses non-incremental mode" do
      klass = child_contract
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :sensors, type: :array
            collection :results, with: :sensors, each: klass, key: :sensor_id, mode: :collect
            aggregate :total, from: :results
            output :total
          end
        end
      end.to raise_error(Igniter::CompileError, /must use mode: :incremental/)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Load guard
  # ─────────────────────────────────────────────────────────────────────────────

  describe "load guard" do
    it "raises a helpful error when extension is not loaded" do
      klass = child_contract

      contract_class = Class.new(Igniter::Contract) do
        define do
          input :sensors, type: :array
          collection :results, with: :sensors, each: klass, key: :sensor_id, mode: :incremental
          aggregate :total, from: :results
          output :total
        end
      end

      dataflow_backup = Igniter::Dataflow
      Igniter.send(:remove_const, :Dataflow)

      begin
        contract = contract_class.new(sensors: [sensor("s1", 10)])
        pattern = %r{require 'igniter/extensions/dataflow'}
        expect { contract.resolve_all }.to raise_error(Igniter::ResolutionError, pattern)
      ensure
        Igniter::Dataflow = dataflow_backup # rubocop:disable Naming/ConstantName
      end
    end
  end
end
