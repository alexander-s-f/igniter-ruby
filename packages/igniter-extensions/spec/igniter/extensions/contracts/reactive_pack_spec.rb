# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::ReactivePack do
  it "runs output subscriptions for matching produced outputs" do
    observed = []
    environment = Igniter::Contracts.with(described_class)

    reactions = described_class.build do
      react_to :output_produced, path: :gross_total do |event:, value:, execution_result:|
        observed << [event.type, event.path, value, execution_result.output(:gross_total)]
      end
    end

    result = described_class.run(environment, inputs: { order_total: 100 }, reactions: reactions) do
      input :order_total
      compute :gross_total, depends_on: [:order_total] do |order_total:|
        order_total * 1.2
      end
      output :gross_total
    end

    expect(result.success?).to eq(true)
    expect(observed).to eq([[:output_produced, :gross_total, 120.0, 120.0]])
  end

  it "passes output values into effect subscriptions" do
    observed = []
    environment = Igniter::Contracts.with(described_class)

    reactions = described_class.build do
      effect :gross_total do |value:, **|
        observed << value
      end
    end

    described_class.run(environment, inputs: { order_total: 100 }, reactions: reactions) do
      input :order_total
      compute :gross_total, depends_on: [:order_total] do |order_total:|
        order_total * 1.2
      end
      output :gross_total
    end

    expect(observed).to eq([120.0])
  end

  it "captures reaction errors without breaking dispatch" do
    environment = Igniter::Contracts.with(described_class)

    reactions = described_class.build do
      effect :order_total do
        raise "side effect failed"
      end
    end

    result = described_class.run(environment, inputs: { order_total: 100 }, reactions: reactions) do
      input :order_total
      output :order_total
    end

    expect(result.output(:order_total)).to eq(100)
    expect(result.errors.length).to eq(1)
    expect(result.errors.first.fetch(:error).message).to eq("side effect failed")
  end

  it "supports execution success, failure, and exit lifecycle hooks" do
    success = []
    failure = []
    exit_statuses = []
    environment = Igniter::Contracts.with(described_class)

    success_reactions = described_class.build do
      on_success do |status:, outputs:, **|
        success << [status, outputs]
      end
      on_exit do |status:, **|
        exit_statuses << status
      end
    end

    success_result = described_class.run(environment, inputs: { amount: 10 }, reactions: success_reactions) do
      input :amount
      output :amount
    end

    failure_reactions = described_class.build do
      on_failure do |status:, execution_error:, **|
        failure << [status, execution_error.message]
      end
      on_exit do |status:, **|
        exit_statuses << status
      end
    end

    failed_result = described_class.run(environment, inputs: { amount: 10 }, reactions: failure_reactions) do
      input :amount
      compute :boom, depends_on: [:amount] do
        raise "boom"
      end
      output :boom
    end

    expect(success_result.success?).to eq(true)
    expect(failed_result.failed?).to eq(true)
    expect(success).to eq([[:succeeded, { amount: 10 }]])
    expect(failure).to eq([[:failed, "boom"]])
    expect(exit_statuses).to eq(%i[succeeded failed])
  end

  it "supports explicit output_changed subscriptions for incremental results" do
    observed = []
    environment = Igniter::Contracts.with(described_class, Igniter::Extensions::Contracts::IncrementalPack)

    session = Igniter::Extensions::Contracts.build_incremental_session(environment) do
      input :order_total
      compute :gross_total, depends_on: [:order_total] do |order_total:|
        order_total * 1.2
      end
      output :gross_total
    end

    reactions = described_class.build do
      react_to :output_changed, path: :gross_total do |event:, **|
        observed << [event.payload[:previous_value], event.payload[:current_value]]
      end
    end

    described_class.run_incremental(session, inputs: { order_total: 100 }, reactions: reactions)
    described_class.run_incremental(session, inputs: { order_total: 150 }, reactions: reactions)

    expect(observed).to eq([[nil, 120.0], [120.0, 180.0]])
  end
end
