# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Differential
        class Report
          attr_reader :primary_name, :candidate_name, :inputs,
                      :primary_outputs, :candidate_outputs,
                      :divergences, :primary_only, :candidate_only,
                      :primary_error, :candidate_error

          def initialize(
            primary_name:,
            candidate_name:,
            inputs:,
            primary_outputs:,
            candidate_outputs:,
            divergences:,
            primary_only:,
            candidate_only:,
            primary_error: nil,
            candidate_error: nil
          )
            @primary_name = primary_name.to_s
            @candidate_name = candidate_name.to_s
            @inputs = inputs.transform_keys(&:to_sym).freeze
            @primary_outputs = primary_outputs.transform_keys(&:to_sym).freeze
            @candidate_outputs = candidate_outputs.transform_keys(&:to_sym).freeze
            @divergences = divergences.freeze
            @primary_only = primary_only.transform_keys(&:to_sym).freeze
            @candidate_only = candidate_only.transform_keys(&:to_sym).freeze
            @primary_error = primary_error&.freeze
            @candidate_error = candidate_error&.freeze
            freeze
          end

          def match?
            divergences.empty? &&
              primary_only.empty? &&
              candidate_only.empty? &&
              primary_error.nil? &&
              candidate_error.nil?
          end

          def summary
            return "match" if match?

            parts = []
            parts << "#{divergences.size} value(s) differ" if divergences.any?
            parts << "#{primary_only.size} output(s) only in primary" if primary_only.any?
            parts << "#{candidate_only.size} output(s) only in candidate" if candidate_only.any?
            parts << "candidate error: #{candidate_error.fetch(:message)}" if candidate_error
            parts << "primary error: #{primary_error.fetch(:message)}" if primary_error
            "diverged - #{parts.join(", ")}"
          end

          def explain
            Formatter.format(self)
          end

          alias to_s explain

          def to_h
            {
              primary: primary_name,
              candidate: candidate_name,
              inputs: inputs,
              match: match?,
              primary_outputs: primary_outputs,
              candidate_outputs: candidate_outputs,
              divergences: divergences.map(&:to_h),
              primary_only: primary_only,
              candidate_only: candidate_only,
              primary_error: primary_error,
              candidate_error: candidate_error
            }
          end
        end
      end
    end
  end
end
