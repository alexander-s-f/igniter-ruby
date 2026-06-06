# frozen_string_literal: true

module Igniter
  module Web
    class MountContext
      attr_reader :mount, :application, :env

      def initialize(mount:, application: nil, env: {})
        @mount = mount
        @application = application
        @env = env.freeze
      end

      def name
        mount.name
      end

      def path
        mount.path
      end

      def metadata
        mount.metadata
      end

      def route(suffix = "")
        normalized_suffix = normalize_suffix(suffix)
        return path if normalized_suffix == "/"
        return normalized_suffix if path == "/"

        "#{path}#{normalized_suffix}"
      end

      def manifest
        application&.manifest
      end

      def layout
        application&.layout
      end

      def service(name)
        application&.service(name)
      end

      def interface(name)
        application&.interface(name)
      end

      def mount_registration
        return nil unless application.respond_to?(:mount?)
        return nil unless application.mount?(name)

        application.mount(name)
      end

      def capabilities
        mount_registration&.capabilities || []
      end

      def to_h
        {
          mount: mount.to_h,
          application: manifest&.to_h,
          metadata: metadata,
          capabilities: capabilities,
          path: path
        }.compact
      end

      private

      def normalize_suffix(value)
        suffix = value.to_s
        suffix = "/#{suffix}" unless suffix.start_with?("/")
        suffix
      end
    end
  end
end
