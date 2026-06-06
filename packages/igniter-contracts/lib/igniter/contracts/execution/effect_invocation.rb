# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class EffectInvocation
        attr_reader :payload, :context, :profile

        def initialize(payload:, context:, profile:)
          @payload = payload
          @context = context.is_a?(NamedValues) ? context : NamedValues.new(context)
          @profile = profile
          freeze
        end

        def to_h
          {
            payload: StructuredDump.dump(payload),
            context: context.to_h,
            profile_fingerprint: profile.fingerprint
          }
        end
      end
    end
  end
end
