# frozen_string_literal: true

require_relative "contracts"
require_relative "lang/types"
require_relative "lang/metadata_manifest"
require_relative "lang/metadata_carrier_manifest"
require_relative "lang/diagnostic_payload"
require_relative "lang/receipt_payload"
require_relative "lang/schema_compatibility_diagnostic"
require_relative "lang/verification_report"
require_relative "lang/backend"
require_relative "lang/backends/ruby"

module Igniter
  module Lang
    History = Types::History
    BiHistory = Types::BiHistory
    OLAPPoint = Types::OLAPPoint
    Forecast = Types::Forecast

    class << self
      def ruby_backend(profile: Igniter::Contracts.default_profile)
        Backends::Ruby.new(profile: profile)
      end
    end
  end
end
