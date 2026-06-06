# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Creator
        class WriteResult
          attr_reader :root, :mode, :steps

          def initialize(root:, mode:, steps:)
            @root = root
            @mode = mode.to_sym
            @steps = steps.freeze
            freeze
          end

          def files_written
            steps.count { |step| step.kind == :file && %i[written unchanged].include?(step.status) }
          end

          def files_skipped
            steps.count { |step| step.kind == :file && step.status == :skipped }
          end

          def directories_created
            steps.count { |step| step.kind == :directory && step.status == :created }
          end

          def success?
            steps.none?(&:actionable?)
          end

          def to_h
            {
              root: root,
              mode: mode,
              files_written: files_written,
              files_skipped: files_skipped,
              directories_created: directories_created,
              success: success?,
              steps: steps.map(&:to_h)
            }
          end
        end
      end
    end
  end
end
