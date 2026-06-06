# frozen_string_literal: true

module Igniter
  module Embed
    Error = Class.new(StandardError)
    DiscoveryError = Class.new(Error)
    DuplicateContractError = Class.new(Error)
    InvalidContractRegistrationError = Class.new(Error)
    SugarError = Class.new(Error)
    UnknownContractError = Class.new(Error)
    UnknownContractableError = Class.new(Error)
    RailsIntegrationError = Class.new(Error)
  end
end
