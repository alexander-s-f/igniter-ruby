# frozen_string_literal: true

require "digest"

module Igniter
  module Extensions
    module Contracts
      module ContentAddressing
        class ContentKey
          attr_reader :hex

          def initialize(hex)
            @hex = hex.freeze
            freeze
          end

          def to_s
            "ca:#{hex}"
          end

          def ==(other)
            other.is_a?(self.class) && other.hex == hex
          end

          alias eql? ==

          def hash
            hex.hash
          end

          class << self
            def compute(fingerprint:, inputs:)
              payload = stable_serialize(inputs)
              new(Digest::SHA256.hexdigest("#{fingerprint}\x00#{payload}")[0..23])
            end

            private

            def stable_serialize(value)
              case value
              when Hash
                pairs = value.sort_by { |key, _entry| key.to_s }.map do |key, entry|
                  "#{key}:#{stable_serialize(entry)}"
                end
                "{#{pairs.join(",")}}"
              when Array
                "[#{value.map { |entry| stable_serialize(entry) }.join(",")}]"
              when String
                value.inspect
              when Symbol
                ":#{value}"
              when Numeric, NilClass, TrueClass, FalseClass
                value.inspect
              else
                value.respond_to?(:to_h) ? stable_serialize(value.to_h) : value.hash.to_s
              end
            end
          end
        end
      end
    end
  end
end
