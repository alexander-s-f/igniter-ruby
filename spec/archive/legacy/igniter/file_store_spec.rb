# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "Igniter file-backed execution store" do
  class FileStoredAsyncExecutor < Igniter::Executor
    input :order_total, type: :numeric

    def call(order_total:)
      defer(token: "file-#{order_total}", payload: { kind: "quote" })
    end
  end

  it "persists and restores snapshots through the file store and job worker" do
    Dir.mktmpdir("igniter-store") do |dir|
      store = Igniter::Runtime::Stores::FileStore.new(root: dir)
      original_store = Igniter.execution_store
      Igniter.execution_store = store

      contract_class = Class.new(Igniter::Contract) do
        run_with runner: :store

        define do
          input :order_total, type: :numeric
          compute :quote_total, depends_on: [:order_total], call: FileStoredAsyncExecutor
          compute :gross_total, depends_on: [:quote_total] do |quote_total:|
            quote_total * 1.2
          end
          output :gross_total
        end
      end

      contract = contract_class.new(order_total: 100)
      contract.result.gross_total
      execution_id = contract.execution.events.execution_id

      expect(store.exist?(execution_id)).to eq(true)

      resumed = contract_class.resume_from_store(execution_id, token: "file-100", value: 150, store: store)

      expect(resumed.result.gross_total).to eq(180.0)
      expect(store.exist?(execution_id)).to eq(false)
    ensure
      Igniter.execution_store = original_store
    end
  end
end
