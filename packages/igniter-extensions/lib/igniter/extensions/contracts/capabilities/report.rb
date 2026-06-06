# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Capabilities
        class Report
          attr_reader :required_capabilities, :profile_capabilities, :violations, :undeclared_nodes

          def initialize(required_capabilities:, profile_capabilities:, violations:, undeclared_nodes:)
            @required_capabilities = required_capabilities.transform_keys(&:to_sym).transform_values do |value|
              Array(value).map(&:to_sym).freeze
            end.freeze
            @profile_capabilities = Array(profile_capabilities).map(&:to_sym).uniq.freeze
            @violations = Array(violations).freeze
            @undeclared_nodes = Array(undeclared_nodes).map(&:to_sym).freeze
            freeze
          end

          def valid?
            violations.empty?
          end

          def invalid?
            !valid?
          end

          def summary
            return "valid" if valid?

            "invalid - #{violations.length} capability violation(s)"
          end

          def to_h
            {
              valid: valid?,
              required_capabilities: required_capabilities,
              profile_capabilities: profile_capabilities,
              undeclared_nodes: undeclared_nodes,
              violations: violations.map(&:to_h)
            }
          end
        end
      end
    end
  end
end
