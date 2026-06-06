# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        class WindowFilter
          def initialize(options)
            @options = options
            validate!
          end

          def apply(items)
            return items unless @options

            if @options.key?(:last)
              items.last(@options.fetch(:last))
            else
              cutoff = Time.now - @options.fetch(:seconds)
              field = @options.fetch(:field).to_sym
              items.select { |item| item.fetch(field) >= cutoff }
            end
          end

          private

          def validate!
            return unless @options
            raise ArgumentError, "window must be a Hash" unless @options.is_a?(Hash)

            if @options.key?(:last)
              return if @options.fetch(:last).is_a?(Integer) && @options.fetch(:last).positive?

              raise ArgumentError, "window { last: } must be a positive Integer"
            end

            if @options.key?(:seconds)
              raise ArgumentError, "window { seconds: } requires a :field key" unless @options.key?(:field)

              return
            end

            raise ArgumentError, "window must use :last or :seconds"
          end
        end
      end
    end
  end
end
