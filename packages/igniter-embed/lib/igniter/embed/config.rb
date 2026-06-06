# frozen_string_literal: true

module Igniter
  module Embed
    class Config
      ContractRegistration = Struct.new(:definition, :name, keyword_init: true)

      attr_reader :name, :packs, :contract_registrations,
                  :contractable_configs, :discovery_pattern
      attr_accessor :cache, :capture_exceptions, :executor_name

      UNSET = Object.new.freeze

      def initialize(name:)
        @name = name.to_sym
        @cache = true
        @root = nil
        @owner = nil
        @packs = []
        @contract_registrations = []
        @contractable_configs = []
        @discovery_enabled = false
        @discovery_pattern = "**/*_contract.rb"
        @capture_exceptions = false
        @executor_name = :inline
      end

      def pack(pack)
        packs << pack
        self
      end

      def owner(value = UNSET)
        return @owner if value.equal?(UNSET)

        @owner = value
        self
      end

      def owner=(value)
        owner(value)
      end

      def contract(definition, as: nil)
        contract_registrations << ContractRegistration.new(definition: definition, name: as)
        self
      end

      def contractable(config)
        raise DuplicateContractError, "contractable #{config.name} is already configured" if contractable_registered?(config.name)

        contractable_configs << config
        self
      end

      def contractable_config(name)
        key = name.to_sym
        contractable_configs.find { |contractable_config| contractable_config.name == key }
      end

      def contracts(&block)
        builder = ContractsBuilder.new(config: self)
        evaluate_builder_block(builder, &block) if block
        self
      end

      def root(path = nil)
        return @root if path.nil?

        @root = File.expand_path(path.to_s)
        self
      end

      def root=(path)
        root(path)
      end

      def path(value = nil)
        return root if value.nil?

        root(resolve_path(value))
      end

      def path=(value)
        path(value)
      end

      def sugar_expansion
        SugarExpansion.new(config: self)
      end

      def discover!(pattern: "**/*_contract.rb")
        @discovery_enabled = true
        @discovery_pattern = pattern
        self
      end

      def cache?
        !!cache
      end

      def discovery_enabled?
        !!@discovery_enabled
      end

      def capture_exceptions?
        !!capture_exceptions
      end

      private

      def contractable_registered?(name)
        contractable_configs.any? { |contractable_config| contractable_config.name == name }
      end

      def resolve_path(value)
        if value.is_a?(Array)
          raise SugarError, "path requires exactly one path in this implementation slice" unless value.length == 1

          value = value.first
        end

        raise SugarError, "path entries must be strings or path-like objects" unless path_like?(value)

        path_value = value.respond_to?(:to_path) ? value.to_path : value.to_s
        return path_value if absolute_path?(path_value)

        owner_root = resolved_owner_root
        owner_root ? File.join(owner_root, path_value) : path_value
      end

      def absolute_path?(path)
        File.absolute_path(path) == path
      end

      def resolved_owner_root
        return nil unless @owner.respond_to?(:root)

        @owner.root.to_s
      end

      def path_like?(value)
        value.is_a?(String) || value.respond_to?(:to_path)
      end

      def evaluate_builder_block(builder, &block)
        if block.arity.zero?
          builder.instance_eval(&block)
        else
          block.call(builder)
        end
      end
    end
  end
end
