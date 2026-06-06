# frozen_string_literal: true

module Igniter
  module Cluster
    class LeasePolicy
      attr_reader :name, :ttl_seconds, :renewable, :metadata, :clock

      def initialize(name:, ttl_seconds: 300, renewable: true, metadata: {}, clock: nil)
        @name = name.to_sym
        @ttl_seconds = Integer(ttl_seconds)
        @renewable = renewable == true
        @metadata = metadata.dup.freeze
        @clock = clock || -> { Time.now.utc }
        freeze
      end

      def self.ephemeral(metadata: {})
        new(name: :ephemeral, metadata: metadata)
      end

      def plan(target:, ownership_plan:, metadata: {})
        if ownership_plan.claims.empty?
          details = plan_metadata(target, ownership_plan, metadata)
          return LeasePlan.new(
            mode: :unleased,
            grants: [],
            metadata: details,
            explanation: DecisionExplanation.new(
              code: :unleased_target,
              message: "no lease granted for #{target}",
              metadata: details
            )
          )
        end

        issued_at = clock.call
        expires_at = issued_at + ttl_seconds
        grants = ownership_plan.claims.map do |claim|
          LeaseGrant.new(
            target: target,
            owner: claim.owner,
            ttl_seconds: ttl_seconds,
            renewable: renewable,
            issued_at: issued_at,
            expires_at: expires_at,
            metadata: {
              policy: name,
              ownership: ownership_plan.to_h
            },
            reason: DecisionExplanation.new(
              code: :lease_granted,
              message: "granted #{ttl_seconds}s lease for #{target} to #{claim.owner.name}",
              metadata: {
                target: target.to_s,
                owner: claim.owner.name,
                ttl_seconds: ttl_seconds,
                policy: name
              }
            )
          )
        end

        details = plan_metadata(target, ownership_plan, metadata)
        LeasePlan.new(
          mode: :granted,
          grants: grants,
          metadata: details,
          explanation: DecisionExplanation.new(
            code: :lease_plan,
            message: "granted #{grants.length} lease(s) for #{target}",
            metadata: details
          )
        )
      end

      def to_h
        {
          name: name,
          ttl_seconds: ttl_seconds,
          renewable: renewable,
          metadata: metadata.dup
        }
      end

      private

      def plan_metadata(target, ownership_plan, extra_metadata)
        {
          policy: to_h,
          target: target.to_s,
          ownership: ownership_plan.to_h
        }.merge(extra_metadata)
      end
    end
  end
end
