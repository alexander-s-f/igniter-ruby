# frozen_string_literal: true

module Igniter
  module Embed
    module Contractable
      module Acceptance
        module_function

        def evaluate(policy:, report:, candidate:, options:)
          case policy.to_sym
          when :exact
            result(policy: :exact, failures: report.match? ? [] : ["differential mismatch"])
          when :completed
            completed = candidate.fetch(:status) != :error && candidate.fetch(:error).nil?
            result(policy: :completed, failures: completed ? [] : ["candidate did not complete"])
          when :shape
            failures = shape_failures(candidate.fetch(:outputs), options.fetch(:outputs, {}))
            result(policy: :shape, failures: failures)
          else
            raise ArgumentError, "unknown contractable acceptance policy #{policy}"
          end
        end

        def result(policy:, failures:)
          {
            policy: policy,
            accepted: failures.empty?,
            failures: failures
          }
        end

        def shape_failures(outputs, expected, path = [])
          expected.flat_map do |key, matcher|
            current_path = path + [key]
            next ["#{current_path.join(".")} is missing"] unless outputs.key?(key)

            value = outputs.fetch(key)
            if matcher.is_a?(Hash)
              value.is_a?(Hash) ? shape_failures(value, matcher, current_path) : ["#{current_path.join(".")} is not a hash"]
            elsif matcher.is_a?(Class) || matcher.is_a?(Module)
              value.is_a?(matcher) ? [] : ["#{current_path.join(".")} is not a #{matcher}"]
            elsif matcher.respond_to?(:call)
              matcher.call(value) ? [] : ["#{current_path.join(".")} did not satisfy predicate"]
            else
              value == matcher ? [] : ["#{current_path.join(".")} did not equal #{matcher.inspect}"]
            end
          end
        end
      end
    end
  end
end
