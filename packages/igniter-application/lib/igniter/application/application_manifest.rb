# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationManifest
      attr_reader :name, :root, :env, :layout, :packs, :contracts, :providers,
                  :services, :interfaces, :scheduled_jobs, :mounts, :config,
                  :credentials, :metadata

      def initialize(name:, root:, env:, layout:, packs: [], contracts: [], providers: [], services: [],
                     interfaces: [], scheduled_jobs: [], mounts: [], config: {}, credentials: {}, metadata: {})
        @name = name.to_sym
        @root = File.expand_path(root.to_s)
        @env = env.to_sym
        @layout = layout
        @packs = Array(packs).map(&:to_s).freeze
        @contracts = Array(contracts).map(&:to_s).freeze
        @providers = Array(providers).map(&:to_sym).freeze
        @services = Array(services).map(&:to_sym).freeze
        @interfaces = Array(interfaces).map(&:to_sym).freeze
        @scheduled_jobs = Array(scheduled_jobs).map(&:to_sym).freeze
        @mounts = Array(mounts).map(&:dup).freeze
        @config = config.dup.freeze
        @credentials = credentials.dup.freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          name: name,
          root: root,
          env: env,
          layout: layout.to_h,
          packs: packs.dup,
          contracts: contracts.dup,
          providers: providers.dup,
          services: services.dup,
          interfaces: interfaces.dup,
          scheduled_jobs: scheduled_jobs.dup,
          mounts: mounts.map(&:dup),
          config: config.dup,
          credentials: credentials.dup,
          metadata: metadata.dup
        }
      end

      def exports
        Array(metadata[:exports]).map(&:dup)
      end

      def imports
        Array(metadata[:imports]).map(&:dup)
      end

      def feature_slices
        Array(metadata[:feature_slices]).map(&:dup)
      end

      def flow_declarations
        Array(metadata[:flow_declarations]).map(&:dup)
      end
    end
  end
end
