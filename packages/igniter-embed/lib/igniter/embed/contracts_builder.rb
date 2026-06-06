# frozen_string_literal: true

module Igniter
  module Embed
    class ContractsBuilder
      def initialize(config:)
        @config = config
      end

      def add(name_or_definition, definition = nil, as: nil, &block)
        name, contract_definition = normalize_add_arguments(name_or_definition, definition, as: as)
        config.contract(contract_definition, as: name)
        build_contractable(name, contract_definition, &block) if block
        self
      end

      private

      attr_reader :config

      def normalize_add_arguments(name_or_definition, definition, as:)
        if ContractNaming.contract_class?(name_or_definition)
          name = as && ContractNaming.normalize_contract_name(as)
          return [name, name_or_definition]
        end

        name = ContractNaming.normalize_contract_name(as || name_or_definition)
        raise InvalidContractRegistrationError, "contract definition is required" unless definition

        [name, definition]
      end

      def build_contractable(name, contract_definition, &block)
        contractable_config = Contractable::Config.new(name: contractable_name(name, contract_definition))
        builder = Contractable::SugarBuilder.new(config: contractable_config)
        if block.arity.zero?
          builder.instance_eval(&block)
        else
          block.call(builder)
        end
        return unless builder.configured?

        config.contractable(contractable_config)
      end

      def contractable_name(name, contract_definition)
        return name if name
        return ContractNaming.infer_contract_name(contract_definition) if ContractNaming.contract_class?(contract_definition)

        raise InvalidContractRegistrationError, "contractable name is required"
      end
    end
  end
end
