# frozen_string_literal: true

module Igniter
  module Application
    BootPhase = Struct.new(:name, :status, keyword_init: true) do
      def initialize(name:, status:)
        super(name: name.to_sym, status: status.to_sym)
        freeze
      end

      def completed?
        status == :completed
      end

      def skipped?
        status == :skipped
      end

      def to_h
        {
          name: name,
          status: status
        }
      end
    end
  end
end
