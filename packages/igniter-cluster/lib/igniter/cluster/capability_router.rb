# frozen_string_literal: true

module Igniter
  module Cluster
    class CapabilityRouter < PolicyRouter
      def initialize(policy: RoutePolicy.capability)
        super(policy: policy)
      end
    end
  end
end
