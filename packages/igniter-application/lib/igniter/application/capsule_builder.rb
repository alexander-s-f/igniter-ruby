# frozen_string_literal: true

module Igniter
  module Application
    class CapsuleBuilder
      attr_reader :name, :root, :env

      def initialize(name, root:, env: :development)
        @name = name.to_sym
        @root = root.to_s
        @env = env.to_sym
        @layout_profile = :standalone
        @groups = []
        @packs = []
        @contracts = []
        @providers = []
        @services = []
        @interfaces = []
        @effects = []
        @agents = []
        @web_surfaces = []
        @exports = []
        @imports = []
        @features = []
        @flows = []
        @config = {}
        @metadata = {}
      end

      def self.build(name, root:, env: :development, &block)
        new(name, root: root, env: env).tap do |builder|
          builder.instance_eval(&block) if block
        end
      end

      def layout(profile)
        @layout_profile = profile.to_sym
        self
      end

      def groups(*names)
        @groups.concat(names.flatten.map(&:to_sym))
        self
      end

      def pack(name)
        @packs << name.to_s
        self
      end

      def contract(name)
        @contracts << name.to_s
        self
      end

      def provider(name)
        @providers << name.to_sym
        self
      end

      def service(name)
        @services << name.to_sym
        self
      end

      def interface(name)
        @interfaces << name.to_sym
        self
      end

      def effect(name)
        @effects << name.to_sym
        self
      end

      def agent(name, model: nil, instructions: nil, tools: [], memory: nil, metadata: {}, **options)
        ai_provider = options.delete(:ai) || :default
        @agents << {
          name: name.to_sym,
          ai_provider: ai_provider.to_sym,
          model: model,
          instructions: instructions,
          tools: tools,
          memory: memory,
          metadata: metadata
        }
        self
      end

      def web_surface(name)
        @web_surfaces << name.to_sym
        self
      end

      def export(name, kind: :service, as: nil, target: nil, metadata: {})
        @exports << {
          name: name.to_sym,
          kind: (as || kind).to_sym,
          target: target,
          metadata: metadata
        }
        self
      end

      def import(name, kind: :service, from: nil, optional: false, capabilities: [], metadata: {})
        @imports << {
          name: name.to_sym,
          kind: kind.to_sym,
          from: from,
          optional: optional,
          capabilities: capabilities,
          metadata: metadata
        }
        self
      end

      def feature(name, &block)
        @features << FeatureBuilder.build(name, &block).to_h
        self
      end

      def flow(name, &block)
        @flows << FlowBuilder.build(name, &block).to_h
        self
      end

      def set(*path, value:)
        cursor = @config
        keys = path.flatten.map(&:to_sym)
        leaf = keys.pop
        keys.each { |key| cursor = (cursor[key] ||= {}) }
        cursor[leaf] = value
        self
      end

      def metadata(values = nil, **entries)
        @metadata.merge!(values) if values
        @metadata.merge!(entries) unless entries.empty?
        self
      end

      def to_blueprint
        ApplicationBlueprint.new(
          name: name,
          root: root,
          env: env,
          layout_profile: @layout_profile,
          groups: @groups.uniq,
          packs: @packs,
          contracts: @contracts,
          providers: @providers,
          services: @services,
          interfaces: @interfaces,
          effects: @effects,
          agents: @agents,
          web_surfaces: @web_surfaces,
          exports: @exports,
          imports: @imports,
          features: @features,
          flows: @flows,
          config: @config,
          metadata: @metadata
        )
      end

      def to_h
        {
          kind: :application_capsule,
          name: name,
          root: root,
          env: env,
          layout_profile: @layout_profile,
          blueprint: to_blueprint.to_h
        }
      end

      class FeatureBuilder
        def initialize(name)
          @name = name.to_sym
          @groups = []
          @paths = {}
          @contracts = []
          @services = []
          @interfaces = []
          @exports = []
          @imports = []
          @flows = []
          @surfaces = []
          @metadata = {}
        end

        def self.build(name, &block)
          new(name).tap do |builder|
            builder.instance_eval(&block) if block
          end
        end

        def groups(*names)
          @groups.concat(names.flatten.map(&:to_sym))
          self
        end

        def path(group, value)
          @paths[group.to_sym] = value.to_s
          self
        end

        def contract(name)
          @contracts << name.to_s
          self
        end

        def service(name)
          @services << name.to_sym
          self
        end

        def interface(name)
          @interfaces << name.to_sym
          self
        end

        def export(name)
          @exports << name.to_sym
          self
        end

        def import(name)
          @imports << name.to_sym
          self
        end

        def flow(name)
          @flows << name.to_sym
          self
        end

        def surface(name)
          @surfaces << name.to_sym
          self
        end

        def metadata(values = nil, **entries)
          @metadata.merge!(values) if values
          @metadata.merge!(entries) unless entries.empty?
          self
        end

        def to_h
          {
            name: @name,
            groups: @groups.uniq,
            paths: @paths.dup,
            contracts: @contracts,
            services: @services,
            interfaces: @interfaces,
            exports: @exports,
            imports: @imports,
            flows: @flows,
            surfaces: @surfaces,
            metadata: @metadata
          }
        end
      end

      class FlowBuilder
        def initialize(name)
          @name = name.to_sym
          @purpose = nil
          @initial_status = :active
          @current_step = nil
          @pending_inputs = []
          @pending_actions = []
          @artifacts = []
          @contracts = []
          @services = []
          @interfaces = []
          @surfaces = []
          @exports = []
          @imports = []
          @metadata = {}
        end

        def self.build(name, &block)
          new(name).tap do |builder|
            builder.instance_eval(&block) if block
          end
        end

        def purpose(value)
          @purpose = value.to_s
          self
        end

        def initial_status(value)
          @initial_status = value.to_sym
          self
        end

        def current_step(value)
          @current_step = value.to_sym
          self
        end

        def pending_input(name, input_type: :text, required: true, target: nil, schema: {}, metadata: {})
          @pending_inputs << {
            name: name,
            input_type: input_type,
            required: required,
            target: target,
            schema: schema,
            metadata: metadata
          }
          self
        end

        def pending_action(name, action_type: :command, target: nil, payload_schema: {}, metadata: {})
          @pending_actions << {
            name: name,
            action_type: action_type,
            target: target,
            payload_schema: payload_schema,
            metadata: metadata
          }
          self
        end

        def artifact(name, uri:, artifact_type: :artifact, summary: nil, metadata: {})
          @artifacts << {
            name: name,
            artifact_type: artifact_type,
            uri: uri,
            summary: summary,
            metadata: metadata
          }
          self
        end

        def contract(name)
          @contracts << name.to_s
          self
        end

        def service(name)
          @services << name.to_sym
          self
        end

        def interface(name)
          @interfaces << name.to_sym
          self
        end

        def surface(name)
          @surfaces << name.to_sym
          self
        end

        def export(name)
          @exports << name.to_sym
          self
        end

        def import(name)
          @imports << name.to_sym
          self
        end

        def metadata(values = nil, **entries)
          @metadata.merge!(values) if values
          @metadata.merge!(entries) unless entries.empty?
          self
        end

        def to_h
          {
            name: @name,
            purpose: @purpose,
            initial_status: @initial_status,
            current_step: @current_step,
            pending_inputs: @pending_inputs,
            pending_actions: @pending_actions,
            artifacts: @artifacts,
            contracts: @contracts,
            services: @services,
            interfaces: @interfaces,
            surfaces: @surfaces,
            exports: @exports,
            imports: @imports,
            metadata: @metadata
          }
        end
      end
    end
  end
end
