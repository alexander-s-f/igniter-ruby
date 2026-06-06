# frozen_string_literal: true

module Igniter
  module DurableModel
    # Normalized return from Store#write.
    # Carries mutation metadata alongside the typed record object.
    # Delegates unknown methods to `record` so callers can use it transparently.
    #
    #   receipt = store.write(Reminder, key: "r1", title: "Buy milk")
    #   receipt.mutation_intent  # => :record_write
    #   receipt.fact_id          # => "550e8400-..."
    #   receipt.value_hash       # => "a3b1c2..."
    #   receipt.causation        # => nil (first write) or previous value_hash
    #   receipt.title            # => "Buy milk"  (delegated to record)
    #   receipt.record           # => #<Reminder ...>
    class WriteReceipt
      attr_reader :mutation_intent, :fact_id, :value_hash, :causation, :key, :record

      def initialize(mutation_intent:, fact_id:, value_hash:, causation:, key:, record:)
        @mutation_intent = mutation_intent
        @fact_id         = fact_id
        @value_hash      = value_hash
        @causation       = causation
        @key             = key
        @record          = record
      end

      def success? = true

      def method_missing(method, *args, &block)
        return @record.public_send(method, *args, &block) if @record.respond_to?(method)

        super
      end

      def respond_to_missing?(method, include_private = false)
        @record.respond_to?(method, include_private) || super
      end

      def inspect
        "#<WriteReceipt intent=#{@mutation_intent} fact_id=#{@fact_id&.slice(0, 8)} key=#{@key.inspect}>"
      end
    end

    # Normalized return from Store#append.
    # Carries mutation metadata alongside the typed event object.
    #
    #   receipt = store.append(TrackerLog, tracker_id: "sleep", value: 8.5)
    #   receipt.mutation_intent  # => :history_append
    #   receipt.fact_id          # => "550e8400-..."
    #   receipt.timestamp        # => 1714483200.123
    #   receipt.event            # => #<TrackerLog ...>
    #   receipt.value            # => 8.5  (delegated to event)
    class AppendReceipt
      attr_reader :mutation_intent, :fact_id, :value_hash, :timestamp, :event

      def initialize(mutation_intent:, fact_id:, value_hash:, timestamp:, event:)
        @mutation_intent = mutation_intent
        @fact_id         = fact_id
        @value_hash      = value_hash
        @timestamp       = timestamp
        @event           = event
      end

      def success? = true

      def method_missing(method, *args, &block)
        return @event.public_send(method, *args, &block) if @event.respond_to?(method)

        super
      end

      def respond_to_missing?(method, include_private = false)
        @event.respond_to?(method, include_private) || super
      end

      def inspect
        "#<AppendReceipt intent=#{@mutation_intent} fact_id=#{@fact_id&.slice(0, 8)}>"
      end
    end

    # App-safe receipt for explicit command activity audit persistence.
    # It intentionally does not expose fact ids, value hashes, or causation.
    class CommandActivityReceipt
      attr_reader :schema_version, :kind, :status, :history, :owner, :command,
                  :subject_key, :activity_status, :store_fact_exposed,
                  :value_hash_exposed, :execution_allowed

      def initialize(history:, owner:, command:, subject_key:, activity_status:,
                     status: :recorded, schema_version: 1,
                     kind: :command_activity_receipt,
                     store_fact_exposed: false, value_hash_exposed: false,
                     execution_allowed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @history = token(history)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @activity_status = token(activity_status)
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        @execution_allowed = execution_allowed ? true : false
        freeze
      end

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          history: history,
          owner: owner,
          command: command,
          subject_key: subject_key,
          activity_status: activity_status,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed,
          execution_allowed: execution_allowed
        }
      end

      private

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end

    # App-safe receipt for explicit command-flow decision history persistence.
    # It intentionally does not expose fact ids, value hashes, or causation.
    class CommandFlowDecisionReceipt
      attr_reader :schema_version, :kind, :status, :receipt_id,
                  :decision_receipt_id, :owner, :view_name, :action, :actor,
                  :meaning_status, :errors, :warnings, :metadata,
                  :generated_at, :store_fact_exposed, :value_hash_exposed

      def initialize(receipt_id:, decision_receipt_id:, owner:, view_name:,
                     action:, actor:, meaning_status:, status: :appended,
                     errors: [], warnings: [], metadata: {},
                     generated_at: Time.now.utc, schema_version: 1,
                     kind: :command_flow_decision_receipt,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @receipt_id = receipt_id
        @decision_receipt_id = decision_receipt_id
        @owner = token(owner)
        @view_name = token(view_name)
        @action = token(action)
        @actor = actor
        @meaning_status = token(meaning_status)
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_value(metadata || {})
        @generated_at = generated_at
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def appended? = status == :appended

      def rejected? = status == :rejected

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          receipt_id: receipt_id,
          decision_receipt_id: decision_receipt_id,
          owner: owner,
          view_name: view_name,
          action: action,
          actor: actor,
          meaning_status: meaning_status,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          generated_at: generated_at,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def normalize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), acc|
            acc[token(key)] = normalize_value(entry)
          end.freeze
        when Array
          value.map { |entry| normalize_value(entry) }.freeze
        else
          value
        end
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end

    # App-safe receipt for explicit evidence export archive persistence.
    # It intentionally does not expose fact ids, value hashes, or causation.
    class CommandFlowEvidenceArchiveReceipt
      attr_reader :schema_version, :kind, :status, :archive_receipt_id,
                  :export_id, :content_hash, :owner, :view_name, :privacy,
                  :meaning_status, :diagnostics, :metadata, :generated_at,
                  :store_fact_exposed, :value_hash_exposed

      def initialize(archive_receipt_id:, export_id:, content_hash:, owner:,
                     view_name:, privacy:, meaning_status:, status: :archived,
                     diagnostics: [], metadata: {}, generated_at: Time.now.utc,
                     schema_version: 1,
                     kind: :command_flow_evidence_archive_receipt,
                     store_fact_exposed: false, value_hash_exposed: false)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @archive_receipt_id = archive_receipt_id
        @export_id = export_id
        @content_hash = content_hash
        @owner = token(owner)
        @view_name = token(view_name)
        @privacy = token(privacy)
        @meaning_status = token(meaning_status)
        @diagnostics = Array(diagnostics).map { |entry| normalize_value(entry) }.freeze
        @metadata = normalize_value(metadata || {})
        @generated_at = generated_at
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        freeze
      end

      def archived? = status == :archived

      def rejected? = status == :rejected

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          archive_receipt_id: archive_receipt_id,
          export_id: export_id,
          content_hash: content_hash,
          owner: owner,
          view_name: view_name,
          privacy: privacy,
          meaning_status: meaning_status,
          diagnostics: diagnostics,
          metadata: metadata,
          generated_at: generated_at,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed
        }
      end

      private

      def normalize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), acc|
            acc[token(key)] = normalize_value(entry)
          end.freeze
        when Array
          value.map { |entry| normalize_value(entry) }.freeze
        else
          value
        end
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end

    # App-boundary receipt for explicit command application.
    # It reports command outcome without exposing Ledger storage internals.
    class CommandApplyReceipt
      attr_reader :schema_version, :kind, :status, :owner, :command,
                  :subject_key, :operation, :target, :mutation_intent,
                  :activity_recorded, :store_fact_exposed,
                  :value_hash_exposed, :execution_boundary, :errors, :warnings

      def initialize(owner:, command:, subject_key:, operation:, target:,
                     mutation_intent:, status: :applied,
                     activity_recorded: false, errors: [], warnings: [],
                     schema_version: 1, kind: :command_apply_receipt,
                     store_fact_exposed: false, value_hash_exposed: false,
                     execution_boundary: :app)
        @schema_version = schema_version
        @kind = token(kind)
        @status = token(status)
        @owner = token(owner)
        @command = token(command)
        @subject_key = subject_key
        @operation = token(operation)
        @target = normalize_value(target)
        @mutation_intent = token(mutation_intent)
        @activity_recorded = activity_recorded ? true : false
        @store_fact_exposed = store_fact_exposed ? true : false
        @value_hash_exposed = value_hash_exposed ? true : false
        @execution_boundary = token(execution_boundary)
        @errors = Array(errors).map { |entry| normalize_value(entry) }.freeze
        @warnings = Array(warnings).map { |entry| normalize_value(entry) }.freeze
        freeze
      end

      def [](key)
        to_h[key.to_sym]
      end

      def to_h
        {
          schema_version: schema_version,
          kind: kind,
          status: status,
          owner: owner,
          command: command,
          subject_key: subject_key,
          operation: operation,
          target: target,
          mutation_intent: mutation_intent,
          activity_recorded: activity_recorded,
          store_fact_exposed: store_fact_exposed,
          value_hash_exposed: value_hash_exposed,
          execution_boundary: execution_boundary,
          errors: errors,
          warnings: warnings
        }
      end

      private

      def normalize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), acc|
            acc[token(key)] = normalize_value(entry)
          end.freeze
        when Array
          value.map { |entry| normalize_value(entry) }.freeze
        else
          value
        end
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end
    end
  end
end
