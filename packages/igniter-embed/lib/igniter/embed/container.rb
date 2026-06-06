# frozen_string_literal: true

module Igniter
  module Embed
    class Container
      attr_reader :config, :registry

      def initialize(config:)
        @config = config
        @registry = Registry.new
        @compiled_contracts = {}
        @contractable_runners = {}
        register_configured_contracts
        discover_configured_contracts
      end

      def profile
        @profile ||= Igniter::Contracts.build_profile(config.packs)
      end

      def register(name_or_definition, definition = nil, as: nil, &block)
        name, contract_definition = normalize_registration(name_or_definition, definition, as: as, block: block)
        raise ArgumentError, "contract definition is required" unless contract_definition

        registry.register(name, contract_definition)
        compiled_contracts.delete(name)
        ContractHandle.new(name: name, container: self)
      end

      def fetch(name)
        registry.fetch(name)
        ContractHandle.new(name: name, container: self)
      end

      def compile(name = nil, &block)
        return compile_block(&block) if block

        compile_registered(name)
      end

      def call(name, inputs = {}, **keyword_inputs)
        normalized_inputs = inputs.merge(keyword_inputs)
        compiled_graph = compile_registered(name)
        result = Igniter::Contracts.execute_with(
          config.executor_name,
          compiled_graph,
          inputs: normalized_inputs,
          profile: profile
        )
        ExecutionEnvelope.new(name: name, inputs: normalized_inputs, result: result)
      rescue StandardError => e
        raise unless config.capture_exceptions?

        ExecutionEnvelope.new(
          name: name,
          inputs: normalized_inputs || {},
          errors: [e],
          metadata: { captured_exception: true }
        )
      end

      def contractable(name)
        key = name.to_sym
        return contractable_runners.fetch(key) if contractable_runners.key?(key)

        contractable_config = config.contractable_config(key)
        raise UnknownContractableError, "unknown contractable #{key}" unless contractable_config

        contractable_runners[key] = Contractable::Runner.new(config: contractable_config)
      end
      alias fetch_contractable contractable

      def contractable_names
        config.contractable_configs.map(&:name)
      end

      def clear_cache
        compiled_contracts.clear
        contractable_runners.clear
        @profile = nil
        self
      end

      def reload!
        clear_cache
      end

      def sugar_expansion
        config.sugar_expansion
      end

      private

      attr_reader :compiled_contracts, :contractable_runners

      def discover_configured_contracts
        return unless config.discovery_enabled?

        root = config.root
        raise DiscoveryError, "config.root is required when discovery is enabled" unless root
        raise DiscoveryError, "contract discovery root does not exist: #{root}" unless Dir.exist?(root)

        before = contract_classes
        Dir[File.join(root, config.discovery_pattern)].sort.each { |path| require path }
        discovered_contract_classes = (contract_classes - before).select { |klass| discoverable_contract_class?(klass) }
        discovered_by_name = discovered_contract_classes.group_by { |klass| ContractNaming.infer_contract_name(klass) }
        duplicates = discovered_by_name.select { |_name, classes| classes.length > 1 }
        unless duplicates.empty?
          duplicate_names = duplicates.keys.sort.map { |name| ":#{name}" }.join(", ")
          raise DiscoveryError,
                "discovered duplicate contract names #{duplicate_names}; use explicit config.contract registrations"
        end

        discovered_by_name.keys.sort.each do |name|
          next if registry.key?(name)

          register(discovered_by_name.fetch(name).first, as: name)
        end
      end

      def contract_classes
        ObjectSpace.each_object(Class).select { |klass| ContractNaming.contract_class?(klass) }
      end

      def discoverable_contract_class?(contract_class)
        !contract_class.name.nil?
      end

      def register_configured_contracts
        config.contract_registrations.each do |registration|
          register(registration.definition, as: registration.name)
        end
      end

      def normalize_registration(name_or_definition, definition, as:, block:)
        if ContractNaming.contract_class?(name_or_definition)
          name = ContractNaming.normalize_contract_name(as || ContractNaming.infer_contract_name(name_or_definition))
          return [name, name_or_definition]
        end

        name = ContractNaming.normalize_contract_name(as || name_or_definition)
        [name, definition || block]
      end

      def compile_block(&block)
        Igniter::Contracts.compile(profile: profile, &block)
      end

      def compile_registered(name)
        key = name.to_sym
        return compiled_contracts.fetch(key) if config.cache? && compiled_contracts.key?(key)

        compiled = compile_registration(registry.fetch(key))
        compiled_contracts[key] = compiled if config.cache?
        compiled
      end

      def compile_registration(registration)
        return compile_block(&registration.definition) if registration.block?

        registration.definition.compile(profile: profile)
      end
    end
  end
end
