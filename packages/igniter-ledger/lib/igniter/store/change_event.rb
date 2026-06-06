# frozen_string_literal: true

require "securerandom"

module Igniter
  module Store
    # Immutable value object emitted after each committed fact write.
    #
    # Carries a compact reference to the committed fact (fact_id, store, key,
    # timestamps, causation) plus a monotonic cursor sequence assigned by the
    # emitting ChangefeedBuffer.
    #
    # The +fact+ field carries the full Fact object for transports (e.g. TCP push)
    # that need the complete payload on delivery. It is not included in +to_h+
    # to keep wire representations compact.
    ChangeEvent = Struct.new(
      :schema_version,
      :id,
      :type,
      :store,
      :key,
      :fact_id,
      :transaction_time,
      :emitted_at,
      :producer,
      :causation,
      :cursor,
      :fact,
      keyword_init: true
    ) do
      def self.from_fact(fact, sequence:)
        new(
          schema_version:   1,
          id:               "change_#{SecureRandom.uuid}",
          type:             :fact_committed,
          store:            fact.store,
          key:              fact.key,
          fact_id:          fact.id,
          transaction_time: fact.transaction_time,
          emitted_at:       Process.clock_gettime(Process::CLOCK_REALTIME),
          producer:         fact.producer,
          causation:        fact.causation,
          cursor:           { sequence: sequence }.freeze,
          fact:             fact
        ).freeze
      end

      def to_h
        {
          schema_version:   schema_version,
          id:               id,
          type:             type,
          store:            store,
          key:              key,
          fact_id:          fact_id,
          transaction_time: transaction_time,
          emitted_at:       emitted_at,
          producer:         producer,
          causation:        causation,
          cursor:           cursor
        }
      end
    end
  end
end
