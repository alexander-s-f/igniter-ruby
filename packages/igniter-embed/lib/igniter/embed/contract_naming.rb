# frozen_string_literal: true

module Igniter
  module Embed
    module ContractNaming
      module_function

      def contract_class?(value)
        value.is_a?(Class) && value < Igniter::Contract
      end

      def infer_contract_name(contract_class)
        class_name = contract_class.name
        unless class_name
          raise InvalidContractRegistrationError,
                "anonymous contract classes must be registered with as:"
        end

        basename = class_name.split("::").last.sub(/Contract\z/, "")
        snake_case(basename).to_sym
      end

      def normalize_contract_name(name)
        raise InvalidContractRegistrationError, "contract name is required" unless name

        name.to_sym
      end

      def snake_case(value)
        value
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .tr("-", "_")
          .downcase
      end
    end
  end
end
