# frozen_string_literal: true

module Igniter
  module Store
    # Engine routing descriptor: how the store routes scope queries for a given store/scope pair.
    AccessPath = Struct.new(
      :store,
      :lookup,
      :scope,
      :filters,
      :cache_ttl,
      :consumers,
      keyword_init: true
    )

    # Retention policy for a store — controls compaction behaviour.
    # strategy: :permanent   — never compact (default)
    #           :ephemeral   — keep only latest fact per key; drop all historical
    #           :rolling_window — drop historical facts older than duration seconds,
    #                             always preserving the latest per key
    # duration: Float seconds (required for :rolling_window)
    RetentionPolicy = Struct.new(
      :strategy,   # Symbol
      :duration,   # Float | nil
      keyword_init: true
    )

    # Derivation rule: when facts matching source_store/source_filters change, call
    # rule.(source_facts) and write the result to target_store at target_key.
    # source_filters: {} means all latest facts per key in that store.
    # rule returning nil skips the derived write.
    # target_key may be a String/Symbol or a callable(Array<Fact>) → String.
    DerivationRule = Struct.new(
      :source_store,    # Symbol
      :source_filters,  # Hash
      :target_store,    # Symbol
      :target_key,      # String | Symbol | callable
      :rule,            # callable(Array<Fact>) → Hash | nil
      keyword_init: true
    )

    # Read-model descriptor: which stores and relations a cross-record projection reads.
    # Metadata-only — no execution happens inside the store engine.
    # Registered in SchemaGraph so the engine knows which projections depend on which stores.
    ProjectionPath = Struct.new(
      :name,           # Symbol — projection name, e.g. :tracker_read_model
      :reads,          # Array<Symbol> — store names this projection reads from
      :relations,      # Array<Symbol> — relation names used when composing sources
      :consumer_hint,  # Symbol — which layer executes this projection (:contract_node, etc.)
      :reactive,       # Boolean — whether push-reactive delivery is expected
      keyword_init: true
    )

    # Declarative relation between two stores.  Backed by a ScatterRule that
    # maintains a materialized index in :"__rel_<name>".
    # source:    Symbol — store whose facts carry the foreign key
    # partition: Symbol — field in source fact's value that holds the FK value
    # target:    Symbol — logical "owning" store (informational / metadata only)
    # Resolved via IgniterStore#resolve(name, from: partition_value).
    RelationRule = Struct.new(
      :name,       # Symbol — relation name, e.g. :article_comments
      :source,     # Symbol — source store
      :partition,  # Symbol — FK field in source fact's value
      :target,     # Symbol — logical target store (metadata only)
      keyword_init: true
    )

    # Scatter derivation rule: when a fact is written to source_store,
    # extract partition_by field from its value to determine the target key,
    # then call rule.(partition_key, existing_value, new_fact) → Hash | nil
    # to update exactly one entry in target_store.
    #
    # Unlike Gather (DerivationRule), Scatter is 1-source → 1-index-entry:
    # the rule accumulates into an existing value rather than re-evaluating
    # the full source set.  rule returning nil skips the write.
    ScatterRule = Struct.new(
      :source_store,  # Symbol — store that triggers the scatter
      :partition_by,  # Symbol — key in source fact's value used as target key
      :target_store,  # Symbol — store where the index entry is written
      :rule,          # callable(partition_key, existing_value, new_fact) → Hash | nil
      keyword_init: true
    )
  end
end
