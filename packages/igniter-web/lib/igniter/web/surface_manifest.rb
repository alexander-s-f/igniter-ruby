# frozen_string_literal: true

module Igniter
  module Web
    class SurfaceManifest
      attr_reader :name, :path, :exports, :imports, :interactions, :metadata

      def self.for(application, name:, path: nil, metadata: {})
        new(
          name: name,
          path: path,
          exports: exports_for(application),
          imports: imports_for(application),
          interactions: interactions_for(application),
          metadata: metadata
        )
      end

      def self.exports_for(application)
        [
          *application.routes.map { |route| route_export(route) },
          *Array(application.api_surface&.endpoints).map { |endpoint| endpoint_export(endpoint) },
          *application.screens.map { |screen| screen_export(screen) },
          *application.mounts.map { |mount| mount_export(mount) }
        ].freeze
      end

      def self.imports_for(application)
        entries = [
          *application.routes.filter_map { |route| target_import(route.target, source: route_source(route)) },
          *Array(application.api_surface&.endpoints).filter_map do |endpoint|
            target_import(endpoint.target, source: endpoint_source(endpoint))
          end,
          *application.screens.flat_map { |screen| screen_imports(screen) }
        ]

        entries.uniq { |entry| [entry.fetch(:kind), entry.fetch(:name)] }.freeze
      end

      def self.interactions_for(application)
        application.screens.each_with_object(empty_interactions) do |screen, memo|
          screen_interactions(screen).each do |kind, entries|
            memo[kind] += entries
          end
        end.transform_values(&:freeze).freeze
      end

      def initialize(name:, path: nil, exports: [], imports: [], interactions: {}, metadata: {})
        @name = name.to_sym
        @path = path
        @exports = exports.map { |entry| deep_freeze(entry) }.freeze
        @imports = imports.map { |entry| deep_freeze(entry) }.freeze
        @interactions = normalize_interactions(interactions)
        @metadata = metadata.dup.freeze
        freeze
      end

      def to_h
        {
          name: name,
          path: path,
          exports: exports.map(&:dup),
          imports: imports.map(&:dup),
          interactions: interactions.transform_values { |entries| entries.map(&:dup) },
          metadata: metadata.dup
        }.compact
      end

      def to_surface_metadata(projections: {})
        normalized_projections = normalize_projection_hash(projections)
        payload = to_h.merge(kind: :web_surface)
        return payload if normalized_projections.empty?

        payload.merge(projection_summary(normalized_projections)).merge(
          projections: normalized_projections
        )
      end

      def to_capsule_export
        {
          name: name,
          kind: :web_surface,
          target: path,
          metadata: metadata.merge(surface_manifest: to_h)
        }
      end

      class << self
        private

        def route_export(route)
          {
            kind: route_kind(route),
            verb: route.verb,
            path: route.path,
            target: serialize_target(route.target),
            metadata: route.metadata
          }
        end

        def endpoint_export(endpoint)
          {
            kind: endpoint.kind,
            verb: endpoint.verb,
            path: endpoint.path,
            target: serialize_target(endpoint.target),
            metadata: endpoint.metadata
          }
        end

        def screen_export(screen)
          spec = screen.respond_to?(:screen) ? screen.screen : screen

          {
            kind: :screen,
            name: spec.name,
            intent: spec.intent,
            metadata: spec.options
          }.compact
        end

        def mount_export(mount)
          {
            kind: :mount,
            path: mount.path,
            target: serialize_target(mount.target),
            metadata: mount.metadata
          }
        end

        def route_kind(route)
          return :page if route.metadata.fetch(:page, false)
          return :screen if route.metadata.fetch(:screen, false)

          :route
        end

        def empty_interactions
          {
            pending_inputs: [],
            pending_actions: [],
            streams: [],
            chats: []
          }
        end

        def screen_interactions(screen)
          spec = screen.respond_to?(:screen) ? screen.screen : screen

          spec.elements.each_with_object(empty_interactions) do |element, memo|
            case element.kind
            when :ask
              memo[:pending_inputs] << pending_input_for(spec, element)
            when :action
              memo[:pending_actions] << pending_action_for(spec, element)
            when :stream
              memo[:streams] << stream_interaction_for(spec, element)
            when :chat
              memo[:chats] << chat_interaction_for(spec, element)
            end
          end
        end

        def pending_input_for(screen, element)
          {
            name: element.name,
            input_type: element.options.fetch(:as, :text),
            required: element.options.fetch(:required, true) != false,
            target: serialize_optional_target(element.options[:resume_with] || element.options[:target]),
            schema: element.options[:schema],
            source: screen_source(screen, element),
            metadata: interaction_metadata(element.options, except: %i[as required resume_with target schema])
          }.compact
        end

        def pending_action_for(screen, element)
          {
            name: element.name,
            action_type: element.options.fetch(:action_type, :command),
            target: serialize_optional_target(element.options[:run]),
            payload_schema: element.options[:payload_schema],
            role: element.role,
            purpose: element.options[:purpose],
            source: screen_source(screen, element),
            metadata: interaction_metadata(
              element.options,
              except: %i[action_type run payload_schema purpose destructive]
            ).merge(destructive: element.options.fetch(:destructive, false))
          }.compact
        end

        def stream_interaction_for(screen, element)
          {
            name: element.name,
            from: serialize_optional_target(element.options[:from]),
            source: screen_source(screen, element),
            metadata: interaction_metadata(element.options, except: %i[from])
          }.compact
        end

        def chat_interaction_for(screen, element)
          {
            name: element.name,
            with: element.name&.to_s,
            source: screen_source(screen, element),
            metadata: interaction_metadata(element.options)
          }.compact
        end

        def screen_imports(screen)
          spec = screen.respond_to?(:screen) ? screen.screen : screen
          spec.elements.filter_map do |element|
            case element.kind
            when :action
              target_import(element.options[:run], kind: :contract, source: screen_source(spec, element))
            when :stream
              target_import(element.options[:from], kind: :projection, source: screen_source(spec, element))
            when :chat
              target_import(element.name, kind: :agent, source: screen_source(spec, element))
            end
          end
        end

        def target_import(target, source:, kind: nil)
          return nil if target.nil?

          resolved = target_to_h(target, kind: kind)
          return nil if resolved.nil?

          resolved.merge(source: source)
        end

        def target_to_h(target, kind: nil)
          return target.to_h if target.respond_to?(:to_h) && target.is_a?(InteractionTarget)
          return nil if kind.nil? && !target.is_a?(String) && !target.is_a?(Symbol)

          name = target.respond_to?(:name) && !target.name.nil? ? target.name : target.to_s
          return nil if name.empty?

          {
            kind: kind || infer_kind(name),
            name: name
          }
        end

        def infer_kind(name)
          case name.to_s
          when /\AContracts::/
            :contract
          when /\AProjections::/
            :projection
          when /\AAgents::/
            :agent
          else
            :target
          end
        end

        def route_source(route)
          {
            kind: route_kind(route),
            verb: route.verb,
            path: route.path
          }
        end

        def endpoint_source(endpoint)
          {
            kind: endpoint.kind,
            verb: endpoint.verb,
            path: endpoint.path
          }
        end

        def screen_source(screen, element)
          {
            kind: :screen,
            screen: screen.name,
            element: element.kind,
            name: element.name
          }.compact
        end

        def serialize_target(target)
          return target.to_h if target.respond_to?(:to_h)
          return target.name if target.respond_to?(:name)

          target.to_s
        end

        def serialize_optional_target(target)
          return nil if target.nil?

          serialize_target(target)
        end

        def interaction_metadata(options, except: [])
          options.reject { |key, _value| except.include?(key) }
        end
      end

      private

      def normalize_interactions(value)
        normalized = self.class.send(:empty_interactions).merge(value)
        normalized.transform_values do |entries|
          Array(entries).map { |entry| deep_freeze(entry) }.freeze
        end.freeze
      end

      def deep_freeze(value)
        case value
        when Hash
          value.transform_values { |entry| deep_freeze(entry) }.freeze
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        else
          value
        end
      end

      def normalize_projection_hash(projections)
        projections.to_h.each_with_object({}) do |(key, value), memo|
          next if value.nil?

          memo[key.to_sym] = symbolize_hash(value.respond_to?(:to_h) ? value.to_h : value)
        end
      end

      def symbolize_hash(value)
        value.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      end

      def projection_summary(projections)
        {}.tap do |summary|
          statuses = projections.values.filter_map { |projection| symbolize_hash(projection)[:status]&.to_sym }.uniq
          flows = projection_flows(projections)
          features = projection_features(projections)

          summary[:status] = summarize_projection_status(statuses) unless statuses.empty?
          summary[:flows] = flows unless flows.empty?
          summary[:features] = features unless features.empty?
        end
      end

      def summarize_projection_status(statuses)
        return :attention if statuses.include?(:attention)
        return statuses.first if statuses.one?

        :mixed
      end

      def projection_flows(projections)
        projections.values.flat_map do |projection|
          source = symbolize_hash(projection)
          flow = symbolize_hash(source.fetch(:flow, {}))
          feature = symbolize_hash(source.fetch(:feature, {}))
          [flow[:name], *Array(feature[:flows])]
        end.compact.map(&:to_sym).uniq
      end

      def projection_features(projections)
        projections.values.filter_map do |projection|
          feature = symbolize_hash(symbolize_hash(projection).fetch(:feature, {}))
          feature[:name]
        end.map(&:to_sym).uniq
      end
    end
  end
end
