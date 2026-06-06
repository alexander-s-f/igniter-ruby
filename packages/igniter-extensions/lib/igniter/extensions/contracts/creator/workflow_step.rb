# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Creator
        class WorkflowStep
          VALID_STATUSES = %i[complete ready needs_attention pending].freeze

          attr_reader :key, :status, :title, :summary, :hints

          def initialize(key:, status:, title:, summary:, hints: [])
            @key = key.to_sym
            @status = normalize_status(status)
            @title = title
            @summary = summary
            @hints = Array(hints).map(&:to_s).uniq.freeze
            freeze
          end

          def complete?
            status == :complete
          end

          def actionable?
            %i[ready needs_attention].include?(status)
          end

          def to_h
            {
              key: key,
              status: status,
              title: title,
              summary: summary,
              hints: hints
            }
          end

          private

          def normalize_status(status)
            value = status.to_sym
            return value if VALID_STATUSES.include?(value)

            raise ArgumentError, "unsupported creator workflow step status #{status.inspect}"
          end
        end
      end
    end
  end
end
