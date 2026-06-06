# frozen_string_literal: true

module Igniter
  module Cluster
    class PolicyAdmission
      attr_reader :policy

      def initialize(policy:)
        @policy = policy
        freeze
      end

      def admit(request:, route:)
        policy.admit(request: request, route: route)
      end
    end
  end
end
