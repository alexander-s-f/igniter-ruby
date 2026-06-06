# frozen_string_literal: true

require_relative "store"

module Igniter
  Ledger = Store unless const_defined?(:Ledger)
end
