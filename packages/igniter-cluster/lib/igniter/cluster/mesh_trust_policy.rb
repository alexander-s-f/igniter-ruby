# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshTrustPolicy
      attr_reader :name, :allowed_peers, :blocked_peers, :required_roles,
                  :required_labels, :required_metadata, :metadata

      def initialize(name:, allowed_peers: nil, blocked_peers: [], required_roles: [],
                     required_labels: {}, required_metadata: {}, metadata: {})
        @name = name.to_sym
        @allowed_peers = normalize_optional_names(allowed_peers)
        @blocked_peers = normalize_names(blocked_peers)
        @required_roles = normalize_names(required_roles)
        @required_labels = normalize_hash(required_labels)
        @required_metadata = normalize_hash(required_metadata)
        @metadata = metadata.dup.freeze
        freeze
      end

      def self.permissive(metadata: {})
        new(name: :permissive, metadata: metadata)
      end

      def admit(peer:, plan_kind:, action:, membership:)
        return denied(peer, :blocked_peer, "mesh trust policy #{name} blocked #{peer.name}", plan_kind, action, membership) if blocked_peers.include?(peer.name)
        return denied(peer, :unlisted_peer, "mesh trust policy #{name} rejected #{peer.name}", plan_kind, action, membership) unless allowed_peer?(peer.name)
        return denied(peer, :missing_roles, "mesh trust policy #{name} requires roles #{required_roles.inspect}", plan_kind, action, membership) unless roles_allowed?(peer)
        return denied(peer, :missing_labels, "mesh trust policy #{name} requires labels #{required_labels.inspect}", plan_kind, action, membership) unless labels_allowed?(peer)
        return denied(peer, :missing_metadata, "mesh trust policy #{name} requires metadata #{required_metadata.inspect}", plan_kind, action, membership) unless metadata_allowed?(peer)

        MeshAdmissionResult.new(
          peer_name: peer.name,
          allowed: true,
          code: accepted_code,
          metadata: result_metadata(peer, plan_kind, action, membership),
          reason: DecisionExplanation.new(
            code: accepted_code,
            message: accepted_message(peer, plan_kind),
            metadata: result_metadata(peer, plan_kind, action, membership)
          )
        )
      end

      def to_h
        {
          name: name,
          allowed_peers: allowed_peers&.dup,
          blocked_peers: blocked_peers.dup,
          required_roles: required_roles.dup,
          required_labels: required_labels.dup,
          required_metadata: required_metadata.dup,
          metadata: metadata.dup
        }
      end

      private

      def normalize_names(values)
        Array(values).map(&:to_sym).uniq.sort.freeze
      end

      def normalize_optional_names(values)
        return nil if values.nil?

        normalize_names(values)
      end

      def normalize_hash(values)
        values.each_with_object({}) do |(key, value), memo|
          memo[key.to_sym] = value
        end.freeze
      end

      def allowed_peer?(peer_name)
        return true if allowed_peers.nil?

        allowed_peers.include?(peer_name)
      end

      def roles_allowed?(peer)
        required_roles.all? { |role| peer.roles.include?(role) }
      end

      def labels_allowed?(peer)
        peer.matches_labels?(required_labels)
      end

      def metadata_allowed?(peer)
        required_metadata.all? do |key, value|
          peer.metadata[key] == value
        end
      end

      def denied(peer, code, message, plan_kind, action, membership)
        details = result_metadata(peer, plan_kind, action, membership)
        MeshAdmissionResult.new(
          peer_name: peer.name,
          allowed: false,
          code: code,
          metadata: details,
          reason: DecisionExplanation.new(
            code: code,
            message: message,
            metadata: details
          )
        )
      end

      def accepted_code
        name == :permissive ? :mesh_permissive_accept : :mesh_trust_accept
      end

      def accepted_message(peer, plan_kind)
        return "permissive mesh admission accepted #{peer.name} for #{plan_kind}" if name == :permissive

        "mesh trust policy #{name} accepted #{peer.name} for #{plan_kind}"
      end

      def result_metadata(peer, plan_kind, action, membership)
        {
          policy: to_h,
          peer: peer.to_h,
          plan_kind: plan_kind.to_sym,
          subject: action.to_h,
          membership: membership.to_h
        }
      end
    end
  end
end
