# frozen_string_literal: true

module Igniter
  module Application
    class ContractRegistry
      def initialize(registrations = {})
        @registrations = registrations.each_with_object({}) do |(name, contract_class), memo|
          memo[name.to_s] = contract_class
        end.freeze
        freeze
      end

      def fetch(name)
        @registrations.fetch(name.to_s)
      end

      def key?(name)
        @registrations.key?(name.to_s)
      end

      def names
        @registrations.keys.sort
      end

      def to_h
        @registrations.dup
      end
    end
  end
end
