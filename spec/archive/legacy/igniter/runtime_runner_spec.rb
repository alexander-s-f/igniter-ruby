# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter runtime runners" do
  it "supports thread_pool runner for independent branches" do
    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :thread_pool, max_workers: 2

      define do
        input :left, type: :numeric
        input :right, type: :numeric

        compute :left_total, depends_on: [:left] do |left:|
          sleep 0.05
          left * 2
        end

        compute :right_total, depends_on: [:right] do |right:|
          sleep 0.05
          right * 3
        end

        output :left_total
        output :right_total
      end
    end

    contract = contract_class.new(left: 10, right: 20)

    expect(contract.result.left_total).to eq(20)
    expect(contract.result.right_total).to eq(60)
    expect(contract.execution.runner_strategy).to eq(:thread_pool)
    expect(contract.execution.max_workers).to eq(2)
  end

  it "deduplicates shared dependency resolution under thread pool execution" do
    call_count = Queue.new

    contract_class = Class.new(Igniter::Contract) do
      run_with runner: :thread_pool, max_workers: 2

      define do
        input :order_total, type: :numeric

        compute :base_total, depends_on: [:order_total] do |order_total:|
          sleep 0.05
          call_count << :called
          order_total * 2
        end

        compute :gross_total, depends_on: [:base_total] do |base_total:|
          base_total + 10
        end

        compute :net_total, depends_on: [:base_total] do |base_total:|
          base_total - 10
        end

        output :gross_total
        output :net_total
      end
    end

    contract = contract_class.new({ order_total: 100 }, runner: :thread_pool, max_workers: 2)

    expect(contract.result.to_h).to eq(gross_total: 210, net_total: 190)
    expect(call_count.size).to eq(1)
  end
end
