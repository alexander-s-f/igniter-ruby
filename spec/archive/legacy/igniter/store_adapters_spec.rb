# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter store adapters" do
  class FakeSnapshotRecord
    attr_accessor :execution_id, :snapshot_json

    class << self
      def reset!
        @records = {}
      end

      def find_or_initialize_by(execution_id:)
        @records ||= {}
        @records[execution_id] ||= new.tap { |record| record.execution_id = execution_id }
      end

      def find_by(execution_id:)
        @records ||= {}
        @records[execution_id]
      end
    end

    def save!
      self.class.send(:find_or_initialize_by, execution_id: execution_id).snapshot_json = snapshot_json
    end

    def destroy!
      self.class.instance_variable_get(:@records).delete(execution_id)
    end
  end

  class FakeRedis
    def initialize
      @data  = {}
      @sets  = Hash.new { |h, k| h[k] = Set.new }
      @hashes = Hash.new { |h, k| h[k] = {} }
    end

    def set(key, value)  = @data[key] = value
    def get(key)         = @data[key]
    def del(key)         = @data.delete(key)
    def exists?(key)     = @data.key?(key) ? 1 : 0
    def sadd(key, val)   = @sets[key].add(val)
    def srem(key, val)   = @sets[key].delete(val)
    def smembers(key)    = @sets[key].to_a
    def hset(key, field, val) = @hashes[key][field] = val
    def hget(key, field)      = @hashes[key][field]
  end

  let(:snapshot) do
    {
      execution_id: "exec-123",
      graph: "AsyncPricingContract",
      inputs: { order_total: 100 },
      states: {
        quote_total: {
          status: :pending,
          value: {
            type: :deferred,
            data: { token: "quote-100", payload: { kind: "pricing_quote" } }
          }
        }
      },
      events: []
    }
  end

  before do
    FakeSnapshotRecord.reset!
  end

  it "saves, fetches, and deletes snapshots through the ActiveRecord adapter" do
    store = Igniter::Runtime::Stores::ActiveRecordStore.new(record_class: FakeSnapshotRecord)

    expect(store.save(snapshot)).to eq("exec-123")
    expect(store.exist?("exec-123")).to eq(true)
    expect(store.fetch("exec-123")).to include("execution_id" => "exec-123", "graph" => "AsyncPricingContract")

    store.delete("exec-123")
    expect(store.exist?("exec-123")).to eq(false)
  end

  it "saves, fetches, and deletes snapshots through the Redis adapter" do
    store = Igniter::Runtime::Stores::RedisStore.new(redis: FakeRedis.new, namespace: "igniter:test")

    expect(store.save(snapshot)).to eq("exec-123")
    expect(store.exist?("exec-123")).to eq(true)
    expect(store.fetch("exec-123")).to include("execution_id" => "exec-123", "graph" => "AsyncPricingContract")

    store.delete("exec-123")
    expect(store.exist?("exec-123")).to eq(false)
  end
end
