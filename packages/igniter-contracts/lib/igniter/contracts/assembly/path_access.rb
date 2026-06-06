# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module PathAccess
        module_function

        NO_DEFAULT = Object.new.freeze

        def normalize_path(keyword_name:, key: nil, dig: nil)
          raise ArgumentError, "#{keyword_name} accepts either key: or dig:, not both" if !key.nil? && !dig.nil?

          raw_path =
            if !key.nil?
              [key]
            elsif !dig.nil?
              Array(dig)
            else
              raise ArgumentError, "#{keyword_name} requires key: or dig:"
            end

          raise ArgumentError, "#{keyword_name} dig: path cannot be empty" if raw_path.empty?

          raw_path.map { |segment| normalize_segment(segment) }
        end

        def fetch_path(source, path, source_name:, keyword_name:, default: NO_DEFAULT)
          current = source

          path.each do |segment|
            if segment_present?(current, segment)
              current = fetch_segment(current, segment)
            else
              return default unless default.equal?(NO_DEFAULT)

              raise KeyError, "#{keyword_name} path #{format_path(path)} not present in #{source_name}"
            end
          end

          current
        end

        def normalize_segment(segment)
          return segment if segment.is_a?(Integer)

          segment.to_sym
        end

        def segment_present?(value, segment)
          if value.respond_to?(:key?)
            value.key?(segment) ||
              (segment.is_a?(Symbol) && value.key?(segment.to_s)) ||
              (segment.is_a?(String) && value.key?(segment.to_sym))
          elsif value.is_a?(Array) && segment.is_a?(Integer)
            segment >= 0 && segment < value.length
          else
            false
          end
        end

        def fetch_segment(value, segment)
          return value.fetch(segment) if value.respond_to?(:key?) && value.key?(segment)
          return value.fetch(segment.to_s) if value.respond_to?(:key?) && segment.is_a?(Symbol) && value.key?(segment.to_s)
          return value.fetch(segment.to_sym) if value.respond_to?(:key?) && segment.is_a?(String) && value.key?(segment.to_sym)

          value.fetch(segment)
        end

        def format_path(path)
          path.map(&:inspect).join(" -> ")
        end
      end
    end
  end
end
