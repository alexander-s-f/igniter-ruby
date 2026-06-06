# frozen_string_literal: true

module Igniter
  module Embed
    class SugarExpansion
      def initialize(config:)
        @config = config
      end

      def to_h
        {
          host: config.name,
          owner: owner_name,
          root: config.root,
          cache: config.cache?,
          contracts: contracts,
          contractables: contractables,
          capabilities: [],
          events: [],
          clean_config: clean_config
        }
      end

      private

      attr_reader :config

      def owner_name
        owner = config.owner
        return nil unless owner
        return owner.name if owner.respond_to?(:name) && owner.name

        owner.inspect
      end

      def contracts
        config.contract_registrations.map do |registration|
          {
            name: registration_name(registration),
            class: registration_class(registration),
            kind: registration_kind(registration)
          }
        end
      end

      def clean_config
        {
          name: config.name,
          owner: owner_name,
          root: config.root,
          cache: config.cache?,
          contracts: contracts
        }
      end

      def contractables
        config.contractable_configs.map do |contractable_config|
          {
            name: contractable_config.name,
            role: contractable_config.role,
            stage: contractable_config.stage,
            primary: callable_name(contractable_config.primary),
            candidate: callable_name(contractable_config.candidate),
            async: contractable_config.async,
            sample: contractable_config.sample,
            metadata: contractable_config.metadata,
            adapters: adapters(contractable_config),
            capabilities: capabilities(contractable_config),
            events: events(contractable_config),
            runner: runner(contractable_config)
          }
        end
      end

      def registration_name(registration)
        return registration.name.to_sym if registration.name
        return ContractNaming.infer_contract_name(registration.definition) if ContractNaming.contract_class?(registration.definition)

        nil
      end

      def registration_class(registration)
        definition = registration.definition
        return definition.name if ContractNaming.contract_class?(definition) && definition.name

        nil
      end

      def registration_kind(registration)
        ContractNaming.contract_class?(registration.definition) ? :class : :block
      end

      def callable_name(callable)
        return nil unless callable
        return callable.name if callable.respond_to?(:name) && callable.name

        callable.inspect
      end

      def adapters(contractable_config)
        {
          normalizer: normalizer_adapter(contractable_config),
          redaction: callable_name(contractable_config.redact_inputs),
          acceptance: acceptance_adapter(contractable_config),
          store: callable_name(contractable_config.store)
        }.compact
      end

      def normalizer_adapter(contractable_config)
        primary = callable_name(contractable_config.normalize_primary)
        candidate = callable_name(contractable_config.normalize_candidate)
        return primary if primary == candidate

        { primary: primary, candidate: candidate }.compact
      end

      def acceptance_adapter(contractable_config)
        {
          policy: contractable_config.accept,
          options: contractable_config.acceptance_options
        }
      end

      def events(contractable_config)
        contractable_config.event_handlers.map do |event_handler|
          {
            event: event_handler.event,
            source: event_handler.source,
            handler: callable_name(event_handler.handler)
          }
        end
      end

      def capabilities(contractable_config)
        contractable_config.capability_attachments.map do |attachment|
          {
            name: attachment.name,
            kind: attachment.kind,
            target: callable_name(attachment.target)
          }
        end
      end

      def runner(contractable_config)
        {
          accessor: "contractable(:#{contractable_config.name})",
          materializable: true
        }
      end
    end
  end
end
