# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshAdmission
      attr_reader :policy

      def initialize(policy:)
        @policy = policy
        freeze
      end

      def admit(peer:, plan_kind:, action:, membership:)
        policy.admit(peer: peer, plan_kind: plan_kind, action: action, membership: membership)
      end

      def to_h
        {
          policy: policy.to_h
        }
      end
    end
  end
end
