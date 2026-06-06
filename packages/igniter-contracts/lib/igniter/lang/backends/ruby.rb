# frozen_string_literal: true

module Igniter
  module Lang
    module Backends
      class Ruby
        include Backend

        attr_reader :profile

        def initialize(profile: Igniter::Contracts.default_profile)
          @profile = profile
        end

        def compile(profile: self.profile, &block)
          Igniter::Contracts.compile(profile: profile, &block)
        end

        def compilation_report(profile: self.profile, &block)
          Igniter::Contracts.compilation_report(profile: profile, &block)
        end

        def execute(artifact, inputs:, profile: self.profile)
          Igniter::Contracts.execute(artifact, inputs: inputs, profile: profile)
        end

        def diagnose(result, profile: self.profile)
          Igniter::Contracts.diagnose(result, profile: profile)
        end

        def verify(artifact = nil, profile: self.profile, &block)
          if block
            report = compilation_report(profile: profile, &block)
            return VerificationReport.from_compilation_report(report)
          end

          VerificationReport.from_artifact(artifact, profile_fingerprint: profile.fingerprint)
        end
      end
    end
  end
end
