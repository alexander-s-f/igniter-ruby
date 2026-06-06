# frozen_string_literal: true

module Igniter
  module Cluster
    class Kernel
      include KernelSeams

      attr_reader :application_kernel, :cluster_packs, :transport_seam, :router_seam,
                  :admission_seam, :placement_seam, :peer_registry_seam, :incident_registry_seam

      def initialize(application_kernel: Igniter::Application.build_kernel)
        @application_kernel = application_kernel
        @cluster_packs = []
        initialize_defaults
      end

      def install_pack(pack)
        if pack.respond_to?(:install_into_cluster_kernel)
          pack.install_into_cluster_kernel(self)
          @cluster_packs |= [pack]
        else
          install_dependent_pack(pack)
        end

        self
      end

      def register_peer(name, capabilities:, transport:, metadata: {}, roles: [], labels: {}, region: nil, zone: nil,
                        health: nil, health_status: :healthy, health_checks: {})
        peer_registry_seam.register(
          Peer.new(
            name: name,
            capabilities: capabilities,
            transport: transport,
            metadata: metadata,
            roles: roles,
            labels: labels,
            region: region,
            zone: zone,
            capability_catalog: capability_catalog,
            health: health,
            health_status: health_status,
            health_checks: health_checks
          )
        )
        self
      end

      def finalize
        Profile.new(
          application_profile: application_kernel.finalize,
          cluster_packs: cluster_packs,
          names: profile_names,
          seams: profile_seams,
          policies: profile_policies,
          capability_catalog: CapabilityCatalog.new(definitions: capability_catalog.definitions).freeze
        )
      end

      private

      def install_dependent_pack(pack)
        if pack.respond_to?(:install_into_application_kernel) || pack.respond_to?(:install_into)
          application_kernel.install_pack(pack)
          return
        end

        raise ArgumentError,
              "cluster pack #{pack.inspect} must implement " \
              "install_into_cluster_kernel, install_into_application_kernel, " \
              "or install_into"
      end
    end
  end
end
