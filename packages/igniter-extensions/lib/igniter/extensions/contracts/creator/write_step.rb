# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Creator
        class WriteStep
          VALID_KINDS = %i[directory file].freeze
          VALID_STATUSES = %i[pending created written skipped unchanged].freeze

          attr_reader :kind, :relative_path, :absolute_path, :status, :reason

          def initialize(kind:, relative_path:, absolute_path:, status:, reason: nil)
            @kind = normalize_kind(kind)
            @relative_path = relative_path.to_s
            @absolute_path = absolute_path.to_s
            @status = normalize_status(status)
            @reason = reason
            freeze
          end

          def actionable?
            status == :pending
          end

          def written?
            %i[created written unchanged].include?(status)
          end

          def skipped?
            status == :skipped
          end

          def to_h
            {
              kind: kind,
              relative_path: relative_path,
              absolute_path: absolute_path,
              status: status,
              reason: reason
            }
          end

          private

          def normalize_kind(kind)
            value = kind.to_sym
            return value if VALID_KINDS.include?(value)

            raise ArgumentError, "unsupported creator write step kind #{kind.inspect}"
          end

          def normalize_status(status)
            value = status.to_sym
            return value if VALID_STATUSES.include?(value)

            raise ArgumentError, "unsupported creator write step status #{status.inspect}"
          end
        end
      end
    end
  end
end
