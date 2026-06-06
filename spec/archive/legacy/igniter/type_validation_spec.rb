# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter type compatibility validation" do
  class StringValueExecutor < Igniter::Executor
    input :order_total, type: :string

    def call(order_total:)
      order_total.upcase
    end
  end

  it "fails compilation when an executor dependency type is incompatible" do
    expect do
      Class.new(Igniter::Contract) do
        define do
          input :order_total, type: :numeric

          compute :normalized_country, depends_on: [:order_total], call: StringValueExecutor
          output :normalized_country
        end
      end
    end.to raise_error(Igniter::ValidationError, /dependency 'order_total' is numeric, expected string/i)
  end

  it "fails compilation when a composition input type is incompatible" do
    child_contract = Class.new(Igniter::Contract) do
      define do
        input :country, type: :string
        output :country
      end
    end

    expect do
      Class.new(Igniter::Contract) do
        define do
          input :order_total, type: :numeric

          compose :child, contract: child_contract, inputs: { country: :order_total }
          output :child
        end
      end
    end.to raise_error(Igniter::ValidationError, /dependency 'order_total' is numeric, expected string/i)
  end
end
