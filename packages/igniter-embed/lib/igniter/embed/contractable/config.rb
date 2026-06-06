# frozen_string_literal: true

module Igniter
  module Embed
    module Contractable
      class Config
        EventHandler = Struct.new(:event, :handler, :source, keyword_init: true)
        CapabilityAttachment = Struct.new(:name, :target, :kind, keyword_init: true)

        FAILURE_EVENTS = %i[primary_error candidate_error acceptance_failure store_error].freeze
        SUPPORTED_EVENTS = (
          %i[primary_success primary_error candidate_success candidate_error divergence acceptance_failure store_error observation] +
          [:failure]
        ).freeze

        attr_reader :name, :event_handlers, :capability_attachments
        attr_accessor :primary_callable, :candidate_callable,
                      :primary_normalizer, :candidate_normalizer,
                      :store_adapter, :observation_callback,
                      :acceptance_policy, :acceptance_options, :clock_callable,
                      :redaction_input_policy

        def initialize(name:)
          @name = name.to_sym
          @role = nil
          @stage = :captured
          @stage_explicit = false
          @async_enabled = true
          @sample_value = 1.0
          @async_adapter = nil
          @metadata_value = {}
          @input_redactor = ->(*, **) { {} }
          @redaction_input_policy = :custom
          @acceptance_policy = :exact
          @acceptance_options = {}
          @event_handlers = []
          @capability_attachments = []
          @clock_callable = Time
        end

        def primary(callable = nil)
          return primary_callable unless callable

          self.primary_callable = callable
          apply_core_contractable_defaults(callable)
        end

        def candidate(callable = nil)
          return candidate_callable unless callable

          self.candidate_callable = callable
          apply_core_contractable_defaults(callable)
        end

        def normalize_primary(callable = nil, &block)
          return primary_normalizer unless callable || block

          self.primary_normalizer = callable || block
        end

        def normalize_candidate(callable = nil, &block)
          return candidate_normalizer unless callable || block

          self.candidate_normalizer = callable || block
        end

        def role(value = nil)
          return @role || inferred_role unless value

          @role = value.to_sym
        end

        def stage(value = nil)
          return @stage unless value

          @stage = value.to_sym
          @stage_explicit = true
        end

        def async(value = nil)
          return @async_enabled if value.nil?

          @async_enabled = !!value
        end

        def sample(value = nil)
          return @sample_value if value.nil?

          @sample_value = value
        end

        def store(value = nil)
          return store_adapter unless value

          self.store_adapter = value
        end

        def async_adapter(value = nil)
          return @async_adapter || default_async_adapter unless value

          @async_adapter = value
        end

        def redact_inputs(callable = nil, &block)
          return @input_redactor unless callable || block

          @input_redactor = callable || block
        end

        def metadata(value = nil, &block)
          return @metadata_value unless value || block

          @metadata_value = block || value
        end

        def on_observation(callable = nil, &block)
          return observation_callback unless callable || block

          self.observation_callback = callable || block
        end

        def on(event, callable = nil, &block)
          handler = callable || block
          raise SugarError, "on :#{event} requires a block or callable" unless handler

          normalized_event = event.to_sym
          raise SugarError, "unsupported event :#{event}" unless SUPPORTED_EVENTS.include?(normalized_event)

          event_names(normalized_event).each do |event_name|
            event_handlers << EventHandler.new(event: event_name, handler: handler, source: normalized_event)
          end
          self
        end

        def handlers_for(event)
          event_handlers.select { |handler| handler.event == event.to_sym }
        end

        def capability(name, target)
          capability_name = name.to_sym
          raise SugarError, "capability :#{capability_name} is already configured" if capability_configured?(capability_name)

          capability_attachments << CapabilityAttachment.new(
            name: capability_name,
            target: target,
            kind: capability_kind(target)
          )
          self
        end

        def accept(policy = nil, **options)
          return acceptance_policy unless policy

          self.acceptance_policy = policy.to_sym
          self.acceptance_options = options
        end

        def validate!
          raise ArgumentError, "contractable #{name} requires a primary callable" unless primary_callable
          raise ArgumentError, "contractable #{name} requires normalize_primary" unless primary_normalizer

          return if observed_service?
          raise ArgumentError, "contractable #{name} requires normalize_candidate when candidate is configured" unless candidate_normalizer
        end

        def observed_service?
          candidate_callable.nil?
        end

        def sampled?
          value = sample_value
          value = value.call if value.respond_to?(:call)
          value.to_f >= 1.0 || rand < value.to_f
        end

        def normalize_inputs(args, kwargs)
          input_redactor.call(*args, **kwargs)
        end

        def metadata_payload
          metadata_value.respond_to?(:call) ? metadata_value.call : metadata_value
        end

        def now
          clock_callable.respond_to?(:now) ? clock_callable.now : clock_callable.call
        end

        private

        attr_reader :sample_value, :input_redactor, :metadata_value

        def event_names(event)
          event == :failure ? FAILURE_EVENTS : [event]
        end

        def capability_kind(target)
          ContractNaming.contract_class?(target) ? :contract : :callable_adapter
        end

        def capability_configured?(name)
          capability_attachments.any? { |attachment| attachment.name == name }
        end

        def inferred_role
          observed_service? ? :observed_service : :migration_candidate
        end

        def default_async_adapter
          async ? Adapters::ThreadAsync.new : Adapters::InlineAsync.new
        end

        def apply_core_contractable_defaults(callable)
          return unless Igniter::Contracts::Contractable.contractable?(callable)

          definition = contractable_definition(callable)
          @role ||= definition.role
          @stage = definition.stage if definition.stage && !@stage_explicit
          merge_core_contractable_metadata(definition.metadata)
        end

        def contractable_definition(callable)
          klass = callable.is_a?(Class) ? callable : callable.class
          klass.contractable_definition
        end

        def merge_core_contractable_metadata(metadata)
          return if metadata.empty? || !@metadata_value.is_a?(Hash)

          @metadata_value = metadata.merge(@metadata_value)
        end
      end
    end
  end
end
