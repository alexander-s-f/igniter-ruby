# frozen_string_literal: true

module Igniter
  module Application
    class ApplicationLayout
      STANDALONE_PATHS = {
        contracts: "app/contracts",
        providers: "app/providers",
        services: "app/services",
        effects: "app/effects",
        packs: "app/packs",
        executors: "app/executors",
        tools: "app/tools",
        agents: "app/agents",
        skills: "app/skills",
        support: "app/support",
        web: "app/web",
        config: "config/igniter.rb",
        spec: "spec/igniter"
      }.freeze
      CAPSULE_PATHS = {
        contracts: "contracts",
        providers: "providers",
        services: "services",
        effects: "effects",
        packs: "packs",
        executors: "executors",
        tools: "tools",
        agents: "agents",
        skills: "skills",
        support: "support",
        web: "web",
        config: "igniter.rb",
        spec: "spec"
      }.freeze
      EXPANDED_CAPSULE_PATHS = STANDALONE_PATHS
      PROFILE_PATHS = {
        standalone: STANDALONE_PATHS,
        capsule: CAPSULE_PATHS,
        expanded_capsule: EXPANDED_CAPSULE_PATHS
      }.freeze
      DEFAULT_PATHS = STANDALONE_PATHS

      attr_reader :root, :profile, :paths, :metadata

      def initialize(root:, profile: :standalone, paths: {}, metadata: {})
        @root = File.expand_path(root.to_s)
        @profile = profile.to_sym
        @paths = paths_for_profile(@profile).merge(symbolize_hash(paths)).freeze
        @metadata = metadata.dup.freeze
        freeze
      end

      def path(name)
        paths.fetch(name.to_sym)
      end

      def absolute_path(name)
        File.expand_path(path(name), root)
      end

      def code_paths
        paths.reject { |name, _path| %i[config spec].include?(name) }
      end

      def to_h
        {
          root: root,
          profile: profile,
          paths: paths.dup,
          absolute_paths: paths.transform_values { |path| File.expand_path(path, root) },
          metadata: metadata.dup
        }
      end

      private

      def symbolize_hash(value)
        value.each_with_object({}) do |(key, entry), memo|
          memo[key.to_sym] = Array(entry).first.to_s
        end
      end

      def paths_for_profile(name)
        PROFILE_PATHS.fetch(name) do
          raise ArgumentError, "unknown application layout profile #{name.inspect}; expected one of: #{PROFILE_PATHS.keys.join(", ")}"
        end
      end
    end
  end
end
