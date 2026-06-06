# frozen_string_literal: true

require "securerandom"

module Igniter
  module Embed
    module Contractable
      class Runner
        OutputsLike = Struct.new(:payload, keyword_init: true) do
          def to_h
            payload
          end
        end
        ExecutionLike = Struct.new(:outputs, keyword_init: true)

        SEVERITY_MAP = {
          observation: :info,
          primary_success: :info,
          candidate_success: :info,
          divergence: :warning,
          acceptance_failure: :warning,
          primary_error: :error,
          candidate_error: :error,
          store_error: :error
        }.freeze

        SUMMARY_MAP = {
          observation: "observation recorded",
          primary_success: "primary succeeded",
          candidate_success: "candidate succeeded",
          divergence: "outputs diverged from primary",
          acceptance_failure: "acceptance policy failed",
          primary_error: "primary raised an error",
          candidate_error: "candidate raised an error",
          store_error: "store adapter raised an error"
        }.freeze

        attr_reader :config

        def initialize(config:)
          @config = config
          @config.validate!
        end

        def call(*args, **kwargs)
          observation_id = generate_observation_id
          primary_result = primary_payload(args, kwargs, observation_id)
          started_at = config.now
          sampled = config.sampled?
          dispatch_event(:primary_success, observation_id: observation_id, observation: nil, error: nil, metadata: { inputs: redacted_inputs(args, kwargs) })

          if sampled
            handoff = build_async_handoff(observation_id, args, kwargs)
            work = -> { observe(observation_id: observation_id, started_at: started_at, primary_result: primary_result, args: args, kwargs: kwargs, sampled: true) }
            dispatch_async(name: config.name, inputs: redacted_inputs(args, kwargs), metadata: metadata_payload, handoff: handoff, &work)
          else
            record_observation(sampled_observation(observation_id: observation_id, started_at: started_at, primary_result: primary_result, args: args, kwargs: kwargs))
          end

          primary_result
        end

        private

        def primary_payload(args, kwargs, observation_id)
          invoke(config.primary_callable, args, kwargs)
        rescue StandardError => e
          dispatch_event(:primary_error, observation_id: observation_id, observation: nil, error: serialize_error(e), metadata: { inputs: safe_redacted_inputs(args, kwargs) })
          raise
        end

        def observe(observation_id:, started_at:, primary_result:, args:, kwargs:, sampled:)
          primary = normalize_side(config.primary_normalizer, primary_result)
          candidate = candidate_payload(args, kwargs)
          report = build_report(primary: primary, candidate: candidate, args: args, kwargs: kwargs)
          acceptance = if candidate
                         Acceptance.evaluate(
                           policy: config.acceptance_policy,
                           report: report,
                           candidate: candidate,
                           options: config.acceptance_options
                         )
                       end

          record_observation(
            observation(
              observation_id: observation_id,
              started_at: started_at,
              finished_at: config.now,
              args: args,
              kwargs: kwargs,
              sampled: sampled,
              primary: primary,
              candidate: candidate,
              report: report,
              acceptance: acceptance
            )
          )
        end

        def sampled_observation(observation_id:, started_at:, primary_result:, args:, kwargs:)
          primary = normalize_side(config.primary_normalizer, primary_result)
          observation(
            observation_id: observation_id,
            started_at: started_at,
            finished_at: config.now,
            args: args,
            kwargs: kwargs,
            sampled: false,
            primary: primary,
            candidate: nil,
            report: nil,
            acceptance: nil
          )
        end

        def candidate_payload(args, kwargs)
          return nil if config.observed_service?

          candidate_result = invoke(config.candidate_callable, args, kwargs)
          normalize_side(config.candidate_normalizer, candidate_result)
        rescue StandardError => e
          {
            status: :error,
            outputs: {},
            metadata: {},
            error: serialize_error(e)
          }
        end

        def normalize_side(normalizer, value)
          normalized = normalizer.call(value)
          {
            status: normalized.fetch(:status, :ok).to_sym,
            outputs: normalize_hash(normalized.fetch(:outputs)),
            metadata: normalize_hash(normalized.fetch(:metadata, {})),
            error: normalized[:error]
          }
        rescue StandardError => e
          {
            status: :error,
            outputs: {},
            metadata: {},
            error: serialize_error(e)
          }
        end

        def build_report(primary:, candidate:, args:, kwargs:)
          return nil unless candidate

          Igniter::Extensions::Contracts::DifferentialPack.compare(
            inputs: redacted_inputs(args, kwargs),
            primary_result: execution_like(primary.fetch(:outputs)),
            candidate_result: execution_like(candidate.fetch(:outputs)),
            primary_name: "#{config.name}:primary",
            candidate_name: "#{config.name}:candidate"
          )
        end

        def observation(observation_id:, started_at:, finished_at:, args:, kwargs:, sampled:, primary:, candidate:, report:, acceptance:)
          {
            schema_version: 1,
            receipt_kind: :contractable_observation,
            observation_id: observation_id,
            name: config.name,
            role: config.role,
            stage: config.stage,
            mode: candidate ? :shadow : :observe,
            async: config.async,
            sampled: sampled,
            status: nil,
            started_at: serialize_time(started_at),
            finished_at: serialize_time(finished_at),
            duration_ms: duration_ms(started_at, finished_at),
            inputs: redacted_inputs(args, kwargs),
            primary: primary,
            candidate: candidate,
            report: report_payload(report),
            match: report&.match?,
            accepted: acceptance&.fetch(:accepted),
            acceptance: acceptance,
            error: candidate&.fetch(:error),
            store_error: nil,
            metadata: metadata_payload,
            redaction: redaction_metadata
          }
        end

        def record_observation(observation)
          if config.store_adapter
            begin
              observation[:status] = observation_status(observation)
              if config.store_adapter.respond_to?(:record_observation)
                config.store_adapter.record_observation(observation)
              else
                config.store_adapter.record(observation)
              end
            rescue StandardError => e
              observation[:store_error] = serialize_error(e)
              observation[:status] = observation_status(observation)
            end
          else
            observation[:status] = observation_status(observation)
          end
          config.observation_callback&.call(observation)
          dispatch_observation_events(observation)
          observation
        end

        def dispatch_observation_events(observation)
          obs_id = observation[:observation_id]
          dispatch_event(:candidate_success, observation_id: obs_id, observation: observation) if candidate_success?(observation)
          dispatch_event(:candidate_error, observation_id: obs_id, observation: observation, error: observation[:error]) if observation[:error]
          dispatch_event(:divergence, observation_id: obs_id, observation: observation) if observation[:match] == false
          dispatch_event(:acceptance_failure, observation_id: obs_id, observation: observation) if observation[:accepted] == false
          dispatch_event(:store_error, observation_id: obs_id, observation: observation, error: observation[:store_error]) if observation[:store_error]
          dispatch_event(:observation, observation_id: obs_id, observation: observation)
        end

        def dispatch_event(event, observation_id:, observation:, error: nil, metadata: {})
          receipt = build_event_receipt(event: event, observation_id: observation_id, observation: observation)
          config.handlers_for(event).each do |event_handler|
            event_handler.handler.call(
              event_payload(
                event: event,
                observation: observation,
                error: error,
                metadata: metadata,
                receipt: receipt
              )
            )
          end
          return unless config.store_adapter.respond_to?(:record_event)

          begin
            config.store_adapter.record_event(receipt)
          rescue StandardError
            nil
          end
        end

        def event_payload(event:, observation:, error:, metadata:, receipt:)
          {
            name: config.name,
            role: config.role,
            stage: config.stage,
            event: event,
            observation: observation,
            report: observation&.fetch(:report, nil),
            error: error,
            metadata: metadata_payload.merge(normalize_hash(metadata)),
            receipt: receipt
          }
        end

        def build_event_receipt(event:, observation_id:, observation:)
          observation_ref = if observation
                              {
                                observation_id: observation[:observation_id],
                                match: observation[:match],
                                accepted: observation[:accepted]
                              }
                            end

          {
            schema_version: 1,
            receipt_kind: :contractable_event,
            event_id: generate_event_id,
            observation_id: observation_id,
            event: event,
            name: config.name,
            occurred_at: serialize_time(config.now),
            severity: SEVERITY_MAP.fetch(event, :info),
            summary: SUMMARY_MAP.fetch(event, event.to_s.tr("_", " ")),
            observation_ref: observation_ref,
            metadata: {}
          }
        end

        def observation_status(observation)
          return :unsampled if observation[:sampled] == false
          return :store_error if observation[:store_error]
          return :candidate_error if observation.dig(:candidate, :status) == :error
          return :acceptance_failed if observation[:accepted] == false
          return :diverged if observation[:match] == false

          :ok
        end

        def redaction_metadata
          {
            input_policy: config.redaction_input_policy,
            output_policy: :none,
            classes: []
          }
        end

        def build_async_handoff(observation_id, args, kwargs)
          {
            schema_version: 1,
            kind: :contractable_async_handoff,
            observation_id: observation_id,
            name: config.name,
            inputs: redacted_inputs(args, kwargs),
            metadata: metadata_payload,
            queued_at: serialize_time(config.now)
          }
        end

        def dispatch_async(name:, inputs:, metadata:, handoff:, &block)
          adapter = config.async_adapter
          params = adapter.method(:enqueue).parameters
          accepts_handoff = params.any? { |(type, pname)| %i[key keyreq].include?(type) && pname == :handoff } ||
                            params.any? { |(type, _)| type == :keyrest }
          if accepts_handoff
            adapter.enqueue(name: name, inputs: inputs, metadata: metadata, handoff: handoff, &block)
          else
            adapter.enqueue(name: name, inputs: inputs, metadata: metadata, &block)
          end
        end

        def candidate_success?(observation)
          candidate = observation[:candidate]
          candidate && candidate[:status] != :error
        end

        def invoke(callable, args, kwargs)
          return Igniter::Contracts::Contractable.invoke(callable, **kwargs).to_h if Igniter::Contracts::Contractable.contractable?(callable)

          callable.call(*args, **kwargs)
        end

        def execution_like(outputs)
          ExecutionLike.new(outputs: OutputsLike.new(payload: outputs))
        end

        def report_payload(report)
          return nil unless report

          {
            match: report.match?,
            summary: report.summary,
            details: report.to_h
          }
        end

        def redacted_inputs(args, kwargs)
          normalize_hash(config.normalize_inputs(args, kwargs))
        end

        def safe_redacted_inputs(args, kwargs)
          redacted_inputs(args, kwargs)
        rescue StandardError
          {}
        end

        def metadata_payload
          normalize_hash(config.metadata_payload)
        end

        def normalize_hash(value)
          value.to_h.transform_keys(&:to_sym)
        end

        def serialize_error(error)
          {
            type: error.class.name,
            message: error.message,
            details: error.respond_to?(:to_h) ? error.to_h : {}
          }
        end

        def serialize_time(value)
          value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
        end

        def duration_ms(started_at, finished_at)
          return nil unless started_at.respond_to?(:to_f) && finished_at.respond_to?(:to_f)

          ((finished_at.to_f - started_at.to_f) * 1000).round(3)
        end

        def generate_observation_id
          "obs_#{SecureRandom.hex(12)}"
        end

        def generate_event_id
          "evt_#{SecureRandom.hex(12)}"
        end
      end
    end
  end
end
