# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::DataflowPack do
  let(:environment) do
    Igniter::Extensions::Contracts.with(
      Igniter::Extensions::Contracts::DataflowPack,
      Igniter::Extensions::Contracts::IncrementalPack
    )
  end

  def sensor(id, value, zone: "north", timestamp: nil)
    payload = { sensor_id: id, value: value, zone: zone }
    payload[:ts] = timestamp if timestamp
    payload
  end

  it "tracks added, changed, removed, and unchanged items with reusable collection results" do
    session = Igniter::Extensions::Contracts.build_dataflow_session(
      environment,
      source: :readings,
      key: :sensor_id
    ) do
      item do
        input :sensor_id
        input :value

        compute :status, depends_on: [:value] do |value:|
          value > 50 ? :critical : :normal
        end

        output :status
        output :value
      end
    end

    first = session.run(inputs: {
                          readings: [sensor("s1", 10), sensor("s2", 80)]
                        })
    second = session.run(inputs: {
                           readings: [sensor("s1", 99), sensor("s2", 80), sensor("s3", 20)]
                         })
    third = session.run(inputs: {
                          readings: [sensor("s1", 99), sensor("s3", 20)]
                        })

    expect(first.diff.added).to eq(%w[s1 s2])
    expect(second.diff.changed).to eq(["s1"])
    expect(second.diff.unchanged).to eq(["s2"])
    expect(second.diff.added).to eq(["s3"])
    expect(second.processed["s1"].output(:status)).to eq(:critical)
    expect(third.diff.removed).to eq(["s2"])
    expect(third.processed.keys).to eq(%w[s1 s3])
    expect(session.collection_diff.explain).to include("removed(1)")
  end

  it "supports feed_diff and applies sliding windows before diffing" do
    session = Igniter::Extensions::Contracts.build_dataflow_session(
      environment,
      source: :readings,
      key: :sensor_id,
      window: { last: 2 }
    ) do
      item do
        input :sensor_id
        input :value
        output :value
      end
    end

    first = session.run(inputs: {
                          readings: [sensor("s1", 10), sensor("s2", 20), sensor("s3", 30)]
                        })
    second = session.feed_diff(add: [sensor("s4", 40)])

    expect(first.processed.keys).to eq(%w[s2 s3])
    expect(second.processed.keys).to eq(%w[s3 s4])
    expect(second.diff.added).to eq(["s4"])
    expect(second.diff.removed).to eq(["s2"])
  end

  it "maintains aggregates incrementally across adds, updates, and removals" do
    session = Igniter::Extensions::Contracts.build_dataflow_session(
      environment,
      source: :readings,
      key: :sensor_id
    ) do
      item do
        input :sensor_id
        input :value
        input :zone

        compute :status, depends_on: [:value] do |value:|
          value > 50 ? :critical : :normal
        end

        output :status
        output :value
        output :zone
      end

      count :total
      count :alerts, matching: ->(item) { item.output(:status) == :critical }
      sum :total_value, using: :value
      avg :avg_value, using: :value
      group_count :by_zone, using: :zone
    end

    session.run(inputs: {
                  readings: [sensor("s1", 10, zone: "north"), sensor("s2", 80, zone: "south")]
                })
    updated = session.feed_diff(
      add: [sensor("s3", 90, zone: "south")],
      update: [sensor("s1", 70, zone: "north")]
    )
    final = session.feed_diff(remove: ["s2"])

    expect(updated.total).to eq(3)
    expect(updated.alerts).to eq(3)
    expect(updated.total_value).to eq(240.0)
    expect(updated.avg_value).to eq(80.0)
    expect(updated.by_zone).to eq({ "north" => 1, "south" => 2 })

    expect(final.total).to eq(2)
    expect(final.alerts).to eq(2)
    expect(final.total_value).to eq(160.0)
    expect(final.by_zone).to eq({ "north" => 1, "south" => 1 })
  end

  it "requires both DataflowPack and IncrementalPack in the profile" do
    dataflow_only = Igniter::Extensions::Contracts.with(described_class)
    incremental_only = Igniter::Extensions::Contracts.with(Igniter::Extensions::Contracts::IncrementalPack)

    expect do
      described_class.session(incremental_only, source: :readings, key: :sensor_id) do
        item do
          input :sensor_id
          output :sensor_id
        end
      end
    end.to raise_error(Igniter::Contracts::Error, /DataflowPack is not installed/)

    expect do
      described_class.session(dataflow_only, source: :readings, key: :sensor_id) do
        item do
          input :sensor_id
          output :sensor_id
        end
      end
    end.to raise_error(Igniter::Contracts::Error, /IncrementalPack is not installed/)
  end

  it "requires an item definition" do
    expect do
      described_class.session(environment, source: :readings, key: :sensor_id) {}
    end.to raise_error(Igniter::Contracts::Error, /requires an `item do \.\.\. end` definition/)
  end
end
