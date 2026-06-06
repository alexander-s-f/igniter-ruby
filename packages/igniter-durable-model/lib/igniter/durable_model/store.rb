# frozen_string_literal: true

require "securerandom"
require "digest"
require "json"
require "time"
require "igniter/ledger"
require "igniter-ledger-client"

module Igniter
  module DurableModel
    # Application-level store that wraps Igniter::Ledger::LedgerStore.
    #
    # Provides typed read/write/scope/append/replay via Record and History schema classes.
    # Acts as the "user side" pressure on igniter-ledger primitives.
    #
    # Usage:
    #   store = Igniter::DurableModel::Store.new                       # in-memory
    #   store = Igniter::DurableModel::Store.new(backend: :file, path: "/tmp/data.wal")
    #   store = Igniter::DurableModel::Store.new(                      # remote server
    #     backend:   :network,
    #     address:   "127.0.0.1:7400",
    #     transport: :tcp    # default; or :unix for Unix domain sockets
    #   )
    #   store = Igniter::DurableModel::Store.new(client: ledger_client) # preferred remote boundary
    #
    #   store.register(Reminder)
    #   store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
    #   store.read(Reminder, key: "r1")
    #   store.scope(Reminder, :open)
    #   store.append(TrackerLog, tracker_id: "t1", value: 8.5)
    #   store.replay(TrackerLog)
    class Store
      def initialize(backend: :memory, path: nil, address: nil, transport: :tcp, client: nil)
        @registered     = Set.new
        @schema_by_store = {}
        @relations_by_name = {}
        @projections_by_name = {}
        @command_flow_views = {}
        if client
          raise ArgumentError, "client: cannot be combined with backend/path/address/transport options" if backend != :memory || path || address || transport != :tcp

          @inner = ClientAdapter.new(client)
          return
        end

        @inner = case backend
        when :memory
          Igniter::Ledger::LedgerStore.new
        when :file
          Igniter::Ledger::LedgerStore.open(path)
        when :network
          if Igniter::Store::NATIVE
            raise NotImplementedError,
                  ":network backend requires the pure-Ruby fallback (NATIVE=false). " \
                  "Rust-native wire deserialisation is planned for Phase 2."
          end
          raise ArgumentError, "address: is required for :network backend" unless address
          nb    = Igniter::Store::NetworkBackend.new(address: address, transport: transport)
          store = Igniter::Ledger::LedgerStore.new(backend: nb)
          nb.replay.each { |fact| store.__send__(:replay, fact) }
          store
        else
          raise ArgumentError, "Unknown backend: #{backend.inspect}. Use :memory, :file, or :network"
        end
      end

      # Register a Record schema — sets up AccessPaths for all declared scopes
      # and auto-wires one_to_many relations with a join key as materialized
      # scatter indexes.  Idempotent: calling register twice with the same class
      # is a no-op.
      #
      # Auto-wire criteria for a declared relation:
      #   cardinality: :one_to_many  AND  join present  AND
      #   kind: :event_owner or :ownership
      def register(schema_class)
        return self if @registered.include?(schema_class)

        @registered << schema_class
        @schema_by_store[schema_class.store_name] = schema_class

        if schema_class.respond_to?(:_scopes) && !client_backed?
          schema_class._scopes.each do |scope_name, opts|
            @inner.register_path(
              Igniter::Store::AccessPath.new(
                store:     schema_class.store_name,
                lookup:    :primary_key,
                scope:     scope_name,
                filters:   opts[:filters],
                cache_ttl: opts[:cache_ttl],
                consumers: []
              )
            )
          end
        end

        if schema_class.respond_to?(:_relations)
          schema_class._relations.each do |rel_name, attrs|
            next unless attrs[:cardinality] == :one_to_many
            next if attrs[:join].nil? || attrs[:join].empty?
            next unless %i[event_owner ownership].include?(attrs[:kind])

            partition = attrs[:join].values.first
            next unless partition

            register_relation(rel_name,
              source: attrs[:to],
              partition: partition,
              target: schema_class.store_name
            )
          end
        end

        # Emit protocol descriptor for OP1/OP2 visibility.
        # Access paths are registered via direct API (to preserve filter semantics);
        # store/history descriptors go through the protocol surface so that
        # metadata_snapshot[:stores] / metadata_snapshot[:histories] reflect all
        # durable-model-managed schemas.
        emit_companion_descriptor(schema_class)

        self
      end

      # Subscribe a callable to scope-level changes.
      # The callable receives (store_name, scope_name) when facts in the store change.
      def on_scope(schema_class, scope_name, &block)
        raise ArgumentError, "on_scope requires a block" unless block

        if client_backed?
          scope_opts = schema_class._scopes[scope_name]
          unless scope_opts
            raise ArgumentError,
                  "No registered scope=#{scope_name.inspect} for store=#{schema_class.store_name.inspect}"
          end

          return @inner.subscribe(stores: [schema_class.store_name]) do |_event|
            block.call(schema_class.store_name, scope(schema_class, scope_name))
          end
        end

        scope_opts = schema_class._scopes[scope_name] || {}
        @inner.register_path(
          Igniter::Store::AccessPath.new(
            store:     schema_class.store_name,
            lookup:    :primary_key,
            scope:     scope_name,
            filters:   scope_opts[:filters],
            cache_ttl: scope_opts[:cache_ttl],
            consumers: [block]
          )
        )
        self
      end

      # Write (upsert) a record. Returns a WriteReceipt wrapping the typed record.
      # Receipt delegates unknown methods to the record, so callers can use it
      # as if it were the record directly (e.g. receipt.title).
      # Also registers schema_class in the schema registry so that resolve
      # returns typed instances without requiring an explicit register call.
      def write(schema_class, key:, **fields)
        @schema_by_store[schema_class.store_name] ||= schema_class
        result = @inner.write(store: schema_class.store_name, key: key, value: fields)
        record = schema_class.new(key: key, **fields)
        WriteReceipt.new(
          mutation_intent: :record_write,
          fact_id:         result_fact_id(result),
          value_hash:      result_value_hash(result),
          causation:       result_causation(result),
          key:             result_key(result, fallback: key),
          record:          record
        )
      end

      # Read the latest value for a key. Returns nil if not found.
      def read(schema_class, key:, as_of: nil)
        result = @inner.read(store: schema_class.store_name, key: key, as_of: as_of)
        return nil if result.respond_to?(:found?) && !result.found?

        value = result.respond_to?(:value) ? result.value : result
        return nil unless value

        schema_class.new(key: key, **value)
      end

      # Query all records matching a registered scope.
      def scope(schema_class, scope_name, as_of: nil)
        if client_backed?
          scope_opts = schema_class._scopes[scope_name]
          unless scope_opts
            raise ArgumentError,
                  "No registered scope=#{scope_name.inspect} for store=#{schema_class.store_name.inspect}"
          end

          result = @inner.query(
            store: schema_class.store_name,
            where: scope_opts[:filters] || {},
            as_of: as_of
          )
          return result.items.map { |item| schema_class.new(key: item[:key], **item[:value]) }
        end

        facts = @inner.query(store: schema_class.store_name, scope: scope_name, as_of: as_of)
        facts.map { |f| schema_class.from_fact(f) }
      end

      # Append an event to a History stream. Returns an AppendReceipt.
      # Receipt delegates unknown methods to the event (e.g. receipt.value).
      def append(history_class, **fields)
        pk    = history_class._partition_key
        result = @inner.append(history: history_class.store_name, event: fields, partition_key: pk)
        event = history_class.new(fact_id: result_fact_id(result), timestamp: result_timestamp(result), **fields)
        AppendReceipt.new(
          mutation_intent: :history_append,
          fact_id:         result_fact_id(result),
          value_hash:      result_value_hash(result),
          timestamp:       result_timestamp(result),
          event:           event
        )
      end

      # Replay events from a History stream.
      # `partition:` filters by the declared partition_key value (e.g. tracker_id: "sleep").
      # `since:` / `as_of:` are timestamp boundaries.
      def replay(history_class, since: nil, as_of: nil, partition: nil)
        pk    = history_class._partition_key
        facts = if partition && pk
          @inner.history_partition(
            store:           history_class.store_name,
            partition_key:   pk,
            partition_value: partition,
            since:           since,
            as_of:           as_of
          )
        else
          @inner.history(store: history_class.store_name, since: since, as_of: as_of)
        end

        facts.map { |f| history_class.from_fact(f) }
      end

      # Declare a named cross-store relation at the Durable Model level.
      # +source+ may be a schema class (store_name is used) or a Symbol.
      # +target+ may be a schema class or Symbol — informational only.
      def register_relation(name, source:, partition:, target:)
        src = source.respond_to?(:store_name) ? source.store_name : source.to_sym
        tgt = target.respond_to?(:store_name) ? target.store_name : target.to_sym
        rel = {
          source: src,
          partition: partition.to_sym,
          target: tgt,
          index_store: :"__rel_#{name}"
        }
        @relations_by_name[name.to_sym] = rel

        if client_backed?
          @inner.register_descriptor(
            schema_version: 1,
            kind:           :relation,
            name:           name,
            from:           { store: tgt, key: :id },
            to:             { store: src, field: partition },
            cardinality:    :many
          )
          return self
        end

        @inner.register_relation(name, source: src, partition: partition, target: tgt)
        self
      end

      # Resolve a named relation for a given partition value.
      # Returns typed Record instances when the source schema class is known
      # (registered via register() or written via write()); otherwise returns
      # raw value Hashes (backward compatible).
      # Returns [] when nothing is indexed for the given partition value.
      #
      # as_of: Float timestamp — when given, reads the index state AND each
      # source value at that point in time (consistent point-in-time snapshot).
      def resolve(relation_name, from:, as_of: nil)
        if client_backed?
          relation = @relations_by_name[relation_name.to_sym]
          raise ArgumentError, "No relation registered: #{relation_name.inspect}" unless relation

          result = @inner.resolve(relation: relation_name, from: from, as_of: as_of)
          source_class = @schema_by_store[relation[:source]]
          return result.results unless source_class

          return result.items.map { |item| source_class.new(key: item[:key], **item[:value]) } if result.items.any?

          if result.results.any? && result.results.all? { |value| value.is_a?(Hash) && value.key?(:id) }
            return result.results.map { |value| source_class.new(key: value[:id], **value) }
          end

          return result.results
        end

        rule = @inner.schema_graph.relation_for(name: relation_name)
        raise ArgumentError, "No relation registered: #{relation_name.inspect}" unless rule

        index_entry = @inner.read(store: :"__rel_#{relation_name}", key: from.to_s, as_of: as_of)
        return [] unless index_entry

        source_class = @schema_by_store[rule.source]

        index_entry[:keys].filter_map do |key|
          value = @inner.read(store: rule.source, key: key, as_of: as_of)
          next unless value
          source_class ? source_class.new(key: key, **value) : value
        end
      end

      # Returns a compact snapshot of all registered relation rules.
      def _relations
        return @relations_by_name.dup if client_backed?

        @inner.schema_graph.relation_snapshot
      end

      # Register a scatter derivation rule at the Durable Model level.
      # Delegates to IgniterStore#register_scatter.  See that method for full semantics.
      # +source_schema+ may be a schema class (its store_name is used) or a Symbol.
      # +target_store+ is always a Symbol (the raw store name for the index).
      def register_scatter(source_schema, partition_by:, target_store:, rule:)
        raise unsupported_client_mode!("scatter registration") if client_backed?

        source = source_schema.respond_to?(:store_name) ? source_schema.store_name : source_schema.to_sym
        @inner.register_scatter(
          source_store: source,
          partition_by: partition_by,
          target_store: target_store,
          rule:         rule
        )
        self
      end

      # Returns a compact snapshot of all registered scatter rules.
      def _scatters
        return normalize_scatter_snapshot(metadata_snapshot[:scatters]) if client_backed?

        @inner.schema_graph.scatter_snapshot
      end

      # Returns command descriptors grouped by owning Record store.
      # Metadata-only: commands remain app-boundary behavior contracts.
      def _commands
        return normalize_command_snapshot(metadata_snapshot[:commands]) if client_backed?

        @inner.schema_graph.command_snapshot
      end

      # Returns derived persistence effect descriptors grouped by owning Record store.
      # Metadata-only: Ledger stores intent descriptors but does not execute app code.
      def _effects
        return normalize_effect_snapshot(metadata_snapshot[:effects]) if client_backed?

        @inner.schema_graph.effect_snapshot
      end

      # Build a pure app-boundary command intent from Record command metadata.
      # This does not execute commands, write facts, append history, or touch Ledger.
      def command_intent(schema_class, command_name, key: nil, params: {}, metadata: {})
        command_key = command_name.to_sym
        command_attrs = command_attrs_for(schema_class, command_key)
        effect_attrs = effect_attrs_for(schema_class, command_key)
        operation = token(command_attrs[:operation] || :none)

        if operation == :record_update && key.nil?
          raise ArgumentError,
                "command_intent requires key: for record_update command=#{command_key.inspect}"
        end

        CommandIntent.new(
          owner: schema_class.store_name,
          command: command_key,
          subject_key: key,
          operation: operation,
          target_shape: command_attrs[:target_shape] || target_shape_for(operation),
          effect: intent_effect(effect_attrs),
          boundary: command_attrs[:boundary] || effect_attrs[:boundary] || :app,
          changes: command_attrs[:changes] || {},
          event: command_attrs[:event],
          params: params,
          metadata: metadata
        )
      end

      # Build a dry-run operation plan for a CommandIntent.
      # Planning may read current state for previews, but never mutates storage.
      def command_operation_plan(intent)
        unless intent.is_a?(CommandIntent)
          raise ArgumentError, "command_operation_plan expects Igniter::DurableModel::CommandIntent"
        end

        case intent.operation
        when :record_update
          plan_record_update(intent)
        when :record_append
          plan_record_append(intent)
        when :history_append
          plan_history_append(intent)
        when :none
          build_command_plan(intent,
            status: :ready,
            target: { shape: :none },
            value: nil,
            event: nil)
        else
          build_command_plan(intent,
            status: :invalid,
            target: { shape: :none },
            errors: [plan_error(:unsupported_operation,
              "Unsupported command operation: #{intent.operation.inspect}")])
        end
      end

      # Project a command intent or plan into app-safe activity data.
      # This does not persist audit history or expose Ledger storage internals.
      def command_activity_event(source, status: nil, metadata: {})
        case source
        when CommandIntent
          activity_from_intent(source, status: status, metadata: metadata)
        when CommandOperationPlan
          activity_from_plan(source, status: status, metadata: metadata)
        else
          raise ArgumentError,
                "command_activity_event expects CommandIntent or CommandOperationPlan"
        end
      end

      # Explicitly persist app-safe command activity into an audit History.
      # This records the activity summary only; it does not apply command effects.
      def append_command_activity(event, history_class: CommandActivity)
        unless event.is_a?(CommandActivityEvent)
          raise ArgumentError, "append_command_activity expects Igniter::DurableModel::CommandActivityEvent"
        end

        register(history_class)
        append(history_class, **command_activity_payload(event))
        CommandActivityReceipt.new(
          history: history_class.store_name,
          owner: event.owner,
          command: event.command,
          subject_key: event.subject_key,
          activity_status: event.status,
          store_fact_exposed: event.store_fact_exposed,
          value_hash_exposed: event.value_hash_exposed,
          execution_allowed: event.execution_allowed
        )
      end

      # Explicit app-boundary command application.
      # Applies only ready CommandOperationPlan data through Durable Model APIs.
      def apply_command(plan, key: nil, history_class: nil, audit: false,
                        activity_history_class: CommandActivity,
                        policy_decision: nil, require_policy: false)
        unless plan.is_a?(CommandOperationPlan)
          raise ArgumentError, "apply_command expects Igniter::DurableModel::CommandOperationPlan"
        end

        decision = policy_decision
        if decision && !decision.is_a?(CommandPolicyDecision)
          raise ArgumentError,
                "policy_decision must be Igniter::DurableModel::CommandPolicyDecision"
        end
        decision ||= command_policy_decision(plan) if require_policy

        if decision && !decision.allowed?
          return rejected_command_apply_receipt(plan,
            errors: policy_decision_errors(decision),
            warnings: decision.warnings,
            policy_decision: decision,
            audit: audit,
            activity_history_class: activity_history_class)
        end

        unless plan.ready?
          return rejected_command_apply_receipt(plan,
            audit: audit,
            activity_history_class: activity_history_class)
        end

        case plan.operation
        when :record_update
          apply_record_update_command(plan,
            audit: audit,
            activity_history_class: activity_history_class,
            policy_decision: decision)
        when :record_append
          apply_record_append_command(plan,
            key: key,
            audit: audit,
            activity_history_class: activity_history_class,
            policy_decision: decision)
        when :history_append
          apply_history_append_command(plan,
            history_class: history_class,
            audit: audit,
            activity_history_class: activity_history_class,
            policy_decision: decision)
        when :none
          applied_command_receipt(plan,
            target: plan.target,
            mutation_intent: :none,
            activity_recorded: record_apply_activity(plan,
              status: :applied,
              audit: audit,
              activity_history_class: activity_history_class,
              policy_decision: decision))
        else
          rejected_command_apply_receipt(plan,
            errors: [plan_error(:unsupported_operation,
              "Unsupported command operation: #{plan.operation.inspect}")],
            audit: audit,
            activity_history_class: activity_history_class)
        end
      end

      # Collapse CommandActivity history for one command attempt into an
      # app-safe lifecycle read model.
      def command_lifecycle(owner:, command:, subject_key: nil, request_id: nil,
                            history_class: CommandActivity)
        events = command_lifecycle_events(
          owner: owner,
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          history_class: history_class
        )
        build_command_lifecycle(
          events,
          owner: owner,
          command: command,
          subject_key: subject_key,
          request_id: request_id
        )
      end

      # Return the typed CommandActivity timeline used by command_lifecycle.
      def command_lifecycle_events(owner:, command: nil, subject_key: nil,
                                   request_id: nil,
                                   history_class: CommandActivity)
        replay(history_class, partition: token(owner)).select do |event|
          command_matches = command.nil? || event.command == token(command)
          subject_matches = subject_key.nil? || event.subject_key == subject_key
          request_matches = request_id.nil? || event.metadata[:request_id] == request_id

          command_matches && subject_matches && request_matches
        end
      end

      # High-level transparent command orchestration. Preview is the default;
      # mutation only happens in mode: :apply via apply_command.
      def command_flow(schema_class, command_name, key: nil, params: {},
                       metadata: {}, actor: nil, capabilities: [],
                       approvals: [], policy: nil, mode: :preview,
                       audit: false, history_class: nil,
                       activity_history_class: CommandActivity)
        flow_mode = token(mode)
        unless %i[preview apply].include?(flow_mode)
          raise ArgumentError, "Unknown command_flow mode: #{mode.inspect}"
        end

        flow_metadata = ensure_command_flow_request_id(metadata)
        intent = command_intent(schema_class, command_name,
          key: key,
          params: params,
          metadata: flow_metadata)
        plan = command_operation_plan(intent)
        policy_decision = command_policy_decision(plan,
          actor: actor,
          capabilities: capabilities,
          approvals: approvals,
          metadata: flow_metadata,
          policy: policy)
        activity_event = command_flow_activity_event(plan, policy_decision)

        if flow_mode == :preview
          append_command_activity(activity_event, history_class: activity_history_class) if audit
          lifecycle = command_flow_lifecycle(activity_event,
            audit: audit,
            history_class: activity_history_class)
          return build_command_flow(mode: flow_mode,
            intent: intent,
            plan: plan,
            activity_event: activity_event,
            policy_decision: policy_decision,
            apply_receipt: nil,
            lifecycle: lifecycle,
            metadata: flow_metadata,
            actor: actor)
        end

        apply_receipt = apply_command(plan,
          key: key,
          history_class: history_class,
          audit: audit,
          activity_history_class: activity_history_class,
          policy_decision: policy_decision)
        lifecycle = command_flow_lifecycle(activity_event,
          audit: audit,
          history_class: activity_history_class,
          apply_receipt: apply_receipt,
          policy_decision: policy_decision)
        build_command_flow(mode: flow_mode,
          intent: intent,
          plan: plan,
          activity_event: activity_event,
          policy_decision: policy_decision,
          apply_receipt: apply_receipt,
          lifecycle: lifecycle,
          metadata: flow_metadata,
          actor: actor)
      end

      # Temporal app-safe read model over CommandActivity history.
      def command_flow_slice(owner:, command: nil, subject_key: nil,
                             request_id: nil, actor: nil, status: nil,
                             since: nil, as_of: nil, limit: nil,
                             history_class: CommandActivity)
        filters = command_flow_slice_filters(
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          actor: actor,
          status: status
        )
        events = replay(history_class,
          partition: token(owner),
          since: temporal_value(since),
          as_of: temporal_value(as_of))
        filtered_events = filter_command_flow_slice_events(events,
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          actor: actor)
        items = command_flow_slice_items(filtered_events,
          owner: owner,
          status: status)
        limited_items = limit ? items.first(limit) : items

        CommandFlowSlice.new(
          owner: owner,
          filters: filters,
          since: since,
          as_of: as_of,
          limit: limit,
          items: limited_items
        )
      end

      def command_flow_summary(...)
        command_flow_slice(...).summary
      end

      # Deterministic monitor evaluation over a command-flow slice.
      def command_flow_monitor(owner:, name: nil, command: nil, subject_key: nil,
                               request_id: nil, actor: nil, status: nil,
                               since: nil, as_of: nil, limit: nil, rules: [],
                               slice: nil, history_class: CommandActivity)
        monitor_slice = slice || command_flow_slice(
          owner: owner,
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          actor: actor,
          status: status,
          since: since,
          as_of: as_of,
          limit: limit,
          history_class: history_class
        )
        normalized_rules = Array(rules).map { |rule| normalize_monitor_rule(rule) }
        observations = normalized_rules.map { |rule| command_flow_monitor_observation(rule, monitor_slice) }
        alerts = observations.select { |observation| observation[:matched] }
        monitor_status = command_flow_monitor_status(alerts)

        CommandFlowMonitorResult.new(
          name: name,
          owner: owner,
          filters: monitor_slice.filters,
          since: monitor_slice.since,
          as_of: monitor_slice.as_of,
          status: monitor_status,
          rules: normalized_rules,
          observations: observations,
          alerts: alerts,
          summary: monitor_slice.summary,
          slice: monitor_slice
        )
      end

      # Register an app-local named operational view over command-flow slices.
      def register_command_flow_view(name, owner:, command: nil,
                                     subject_key: nil, request_id: nil,
                                     actor: nil, status: nil, horizon: {},
                                     action_policy: {}, rules: [],
                                     metadata: {})
        descriptor = CommandFlowViewDescriptor.new(
          name: name,
          owner: owner,
          filters: command_flow_slice_filters(
            command: command,
            subject_key: subject_key,
            request_id: request_id,
            actor: actor,
            status: status
          ),
          horizon: normalize_command_flow_view_horizon(horizon),
          action_policy: action_policy,
          rules: rules,
          metadata: metadata
        )
        @command_flow_views[descriptor.name] = descriptor
        descriptor
      end

      def _command_flow_views
        @command_flow_views.transform_values(&:to_h)
      end

      # Evaluate a named app-local command-flow operational view.
      def command_flow_view(name, since: nil, as_of: nil, limit: nil,
                            overrides: {}, history_class: CommandActivity)
        descriptor = command_flow_view_descriptor(name)
        horizon = normalize_command_flow_view_horizon(descriptor.horizon)
        build_command_flow_view(
          descriptor,
          since: since,
          as_of: as_of,
          limit: limit,
          overrides: overrides,
          history_class: history_class,
          horizon: horizon
        )
      end

      # Pin a named operational view into reproducible app-owned decision evidence.
      def pin_command_flow_view(name, action:, actor: nil, capabilities: [],
                                since: nil, as_of: nil, limit: nil,
                                overrides: {}, metadata: {},
                                history_class: CommandActivity)
        raise ArgumentError, "action: is required" if action.nil?

        descriptor = command_flow_view_descriptor(name)
        pinned_as_of = as_of || Time.now.utc
        horizon = pinned_command_flow_view_horizon(descriptor, pinned_as_of)
        normalized_capabilities = Array(capabilities).map { |value| token(value) }
        normalized_action = token(action)
        normalized_metadata = normalize_value(metadata || {})
        generated_at = Time.now.utc
        view = build_command_flow_view(
          descriptor,
          since: since,
          as_of: pinned_as_of,
          limit: limit,
          overrides: overrides,
          history_class: history_class,
          horizon: horizon
        )
        missing_capabilities = command_flow_view_missing_capabilities(
          view.action_policy,
          normalized_capabilities
        )
        errors = command_flow_view_pin_errors(
          view,
          normalized_action,
          missing_capabilities
        )
        allowed = errors.empty? && view.actionable?(
          normalized_action,
          capabilities: normalized_capabilities
        )
        status = allowed ? :pinned : :blocked
        meaning_status = command_flow_view_pin_meaning_status(
          horizon,
          allowed
        )
        receipt = command_flow_view_pin_receipt(
          view,
          action: normalized_action,
          actor: actor,
          status: status,
          meaning_status: meaning_status,
          horizon: horizon,
          capabilities: normalized_capabilities,
          missing_capabilities: missing_capabilities,
          metadata: normalized_metadata,
          generated_at: generated_at
        )

        CommandFlowViewPin.new(
          status: status,
          meaning_status: meaning_status,
          name: view.name,
          owner: view.owner,
          action: normalized_action,
          actor: actor,
          capabilities: normalized_capabilities,
          missing_capabilities: missing_capabilities,
          horizon: horizon,
          view: view,
          receipt: receipt,
          errors: errors,
          metadata: normalized_metadata,
          generated_at: generated_at
        )
      end

      # Explicitly persist a command-flow view pin decision into app-owned history.
      def append_command_flow_decision(pin,
                                       history_class: CommandFlowDecision,
                                       metadata: {})
        unless pin.is_a?(CommandFlowViewPin)
          raise ArgumentError, "append_command_flow_decision expects Igniter::DurableModel::CommandFlowViewPin"
        end

        register(history_class)
        merged_metadata = command_flow_decision_metadata(pin, metadata)
        decision_receipt_id = "cfd_#{SecureRandom.hex(8)}"
        append(history_class, **command_flow_decision_payload(
          pin,
          decision_receipt_id: decision_receipt_id,
          metadata: merged_metadata
        ))

        CommandFlowDecisionReceipt.new(
          receipt_id: pin.receipt[:receipt_id],
          decision_receipt_id: decision_receipt_id,
          owner: pin.owner,
          view_name: pin.name,
          action: pin.action,
          actor: pin.actor,
          meaning_status: pin.meaning_status,
          errors: pin.errors,
          warnings: pin.warnings,
          metadata: merged_metadata,
          store_fact_exposed: pin.store_fact_exposed,
          value_hash_exposed: pin.value_hash_exposed
        )
      end

      # Replay app-owned decision history for command-flow operational views.
      def command_flow_decisions(owner:, view_name: nil, action: nil,
                                 actor: nil, status: nil,
                                 meaning_status: nil, receipt_id: nil,
                                 decision_receipt_id: nil,
                                 since: nil, as_of: nil, limit: nil,
                                 history_class: CommandFlowDecision)
        decisions = replay(history_class,
          partition: token(owner),
          since: temporal_value(since),
          as_of: temporal_value(as_of))
        filtered = decisions.select do |decision|
          command_flow_decision_matches?(
            decision,
            view_name: view_name,
            action: action,
            actor: actor,
            status: status,
            meaning_status: meaning_status,
            receipt_id: receipt_id,
            decision_receipt_id: decision_receipt_id
          )
        end
        limit ? filtered.first(limit) : filtered
      end

      # Compact app-safe review over persisted command-flow decision history.
      def command_flow_decision_review(owner:, view_name: nil, action: nil,
                                       actor: nil, status: nil,
                                       meaning_status: nil, receipt_id: nil,
                                       decision_receipt_id: nil, since: nil,
                                       as_of: nil, limit: nil, rules: [],
                                       metadata: {},
                                       history_class: CommandFlowDecision)
        decisions = command_flow_decisions(
          owner: owner,
          view_name: view_name,
          action: action,
          actor: actor,
          status: status,
          meaning_status: meaning_status,
          receipt_id: receipt_id,
          decision_receipt_id: decision_receipt_id,
          since: since,
          as_of: as_of,
          limit: limit,
          history_class: history_class
        )
        summary = command_flow_decision_review_summary(decisions)
        normalized_rules = Array(rules).map do |rule|
          normalize_decision_review_rule(rule)
        end
        findings = normalized_rules.filter_map do |rule|
          command_flow_decision_review_finding(rule, summary)
        end
        review_status = command_flow_decision_review_status(findings)

        CommandFlowDecisionReview.new(
          owner: owner,
          filters: command_flow_decision_review_filters(
            view_name: view_name,
            action: action,
            actor: actor,
            status: status,
            meaning_status: meaning_status,
            receipt_id: receipt_id,
            decision_receipt_id: decision_receipt_id
          ),
          status: review_status,
          meaning_status: meaning_status || :mixed,
          horizon: { since: since, as_of: as_of, limit: limit }.compact,
          summary: summary,
          findings: findings,
          decisions: decisions,
          metadata: metadata
        )
      end

      # Bundle command-flow view, optional pin, and decision review evidence.
      def command_flow_evidence_profile(view_name:, action: nil, actor: nil,
                                        capabilities: [], since: nil,
                                        as_of: nil, decision_status: nil,
                                        decision_meaning_status: nil,
                                        decision_receipt_id: nil,
                                        decision_limit: nil,
                                        decision_rules: [], metadata: {})
        view = command_flow_view(view_name, since: since, as_of: as_of)
        pin = if action
          pin_command_flow_view(view_name,
            action: action,
            actor: actor,
            capabilities: capabilities,
            since: since,
            as_of: as_of,
            metadata: metadata)
        end
        review = command_flow_decision_review(
          owner: view.owner,
          view_name: view.name,
          action: action,
          actor: actor,
          status: decision_status,
          meaning_status: decision_meaning_status,
          decision_receipt_id: decision_receipt_id,
          since: since,
          as_of: as_of,
          limit: decision_limit,
          rules: decision_rules,
          metadata: metadata
        )
        links = command_flow_evidence_profile_links(
          owner: view.owner,
          view_name: view.name,
          pin: pin,
          review: review
        )
        packets = command_flow_evidence_packets(
          view: view,
          pin: pin,
          review: review
        )

        CommandFlowEvidenceProfile.new(
          owner: view.owner,
          view_name: view.name,
          action: action,
          actor: actor,
          status: command_flow_evidence_profile_status(view, pin, review),
          meaning_status: command_flow_evidence_profile_meaning_status(view, pin, review),
          horizon: command_flow_evidence_profile_horizon(view, pin, review),
          view: view,
          pin: pin,
          review: review,
          decisions: review.decisions,
          packets: packets,
          links: links,
          metadata: metadata
        )
      end

      # Export an existing evidence profile into a deterministic app-safe envelope.
      def export_command_flow_evidence_profile(profile, privacy: :app_safe,
                                               include_packets: true,
                                               include_decisions: true,
                                               metadata: {})
        unless profile.is_a?(CommandFlowEvidenceProfile)
          raise ArgumentError, "export_command_flow_evidence_profile expects Igniter::DurableModel::CommandFlowEvidenceProfile"
        end

        export_payload = command_flow_evidence_export_payload(
          profile,
          privacy: privacy,
          include_packets: include_packets,
          include_decisions: include_decisions,
          metadata: metadata
        )
        canonical_json = command_flow_evidence_canonical_json(export_payload)
        content_hash = Digest::SHA256.hexdigest(canonical_json)

        CommandFlowEvidenceExport.new(
          export_id: "cfe_#{content_hash[0, 16]}",
          profile_kind: profile.kind,
          owner: profile.owner,
          view_name: profile.view_name,
          action: profile.action,
          actor: profile.actor,
          status: profile.status,
          meaning_status: profile.meaning_status,
          privacy: privacy,
          generated_at: profile.generated_at,
          content_hash: content_hash,
          canonical_json: canonical_json,
          profile: export_payload[:profile],
          packets: export_payload[:packets],
          links: export_payload[:links],
          diagnostics: export_payload[:diagnostics],
          redactions: export_payload[:redactions],
          metadata: export_payload[:metadata],
          store_fact_exposed: profile.store_fact_exposed,
          value_hash_exposed: profile.value_hash_exposed
        )
      end

      # Convenience profile builder plus export, still read-only.
      def command_flow_evidence_export(view_name:, action: nil, actor: nil,
                                       capabilities: [], since: nil,
                                       as_of: nil, decision_status: nil,
                                       decision_meaning_status: nil,
                                       decision_receipt_id: nil,
                                       decision_limit: nil,
                                       decision_rules: [],
                                       privacy: :app_safe,
                                       include_packets: true,
                                       include_decisions: true,
                                       metadata: {})
        profile = command_flow_evidence_profile(
          view_name: view_name,
          action: action,
          actor: actor,
          capabilities: capabilities,
          since: since,
          as_of: as_of,
          decision_status: decision_status,
          decision_meaning_status: decision_meaning_status,
          decision_receipt_id: decision_receipt_id,
          decision_limit: decision_limit,
          decision_rules: decision_rules,
          metadata: metadata
        )
        export_command_flow_evidence_profile(profile,
          privacy: privacy,
          include_packets: include_packets,
          include_decisions: include_decisions,
          metadata: metadata)
      end

      # Verify an evidence export without appending anything.
      def verify_command_flow_evidence_export(export, metadata: {})
        unless export.is_a?(CommandFlowEvidenceExport)
          raise ArgumentError, "verify_command_flow_evidence_export expects Igniter::DurableModel::CommandFlowEvidenceExport"
        end

        command_flow_evidence_verification(
          export_id: export.export_id,
          expected_hash: export.content_hash,
          canonical_json: export.canonical_json,
          privacy: export.privacy,
          metadata: metadata
        )
      end

      # Verify an archived evidence export without appending anything.
      def verify_command_flow_evidence_archive(archive, metadata: {})
        unless archive.is_a?(CommandFlowEvidenceArchive)
          raise ArgumentError, "verify_command_flow_evidence_archive expects Igniter::DurableModel::CommandFlowEvidenceArchive"
        end

        command_flow_evidence_verification(
          export_id: archive.export_id,
          expected_hash: archive.content_hash,
          canonical_json: archive.canonical_json,
          privacy: archive.privacy,
          metadata: metadata
        )
      end

      # Explicitly persist a verified evidence export into app-owned archive history.
      def archive_command_flow_evidence_export(export,
                                               history_class: CommandFlowEvidenceArchive,
                                               metadata: {})
        unless export.is_a?(CommandFlowEvidenceExport)
          raise ArgumentError, "archive_command_flow_evidence_export expects Igniter::DurableModel::CommandFlowEvidenceExport"
        end

        verification = verify_command_flow_evidence_export(export)
        merged_metadata = export.metadata.merge(normalize_value(metadata || {}))
        archive_receipt_id = "cfea_#{SecureRandom.hex(8)}"
        unless verification.valid?
          return command_flow_evidence_archive_receipt(
            export,
            archive_receipt_id: archive_receipt_id,
            status: :rejected,
            diagnostics: verification.diagnostics,
            metadata: merged_metadata
          )
        end

        register(history_class)
        append(history_class, **command_flow_evidence_archive_payload(
          export,
          metadata: merged_metadata
        ))
        command_flow_evidence_archive_receipt(
          export,
          archive_receipt_id: archive_receipt_id,
          status: :archived,
          diagnostics: export.diagnostics,
          metadata: merged_metadata
        )
      end

      # Replay app-owned evidence export archives by owner partition.
      def command_flow_evidence_archives(owner:, view_name: nil, action: nil,
                                         actor: nil, export_id: nil,
                                         content_hash: nil, privacy: nil,
                                         status: nil, meaning_status: nil,
                                         since: nil, as_of: nil, limit: nil,
                                         history_class: CommandFlowEvidenceArchive)
        archives = replay(history_class,
          partition: token(owner),
          since: temporal_value(since),
          as_of: temporal_value(as_of))
        filtered = archives.select do |archive|
          command_flow_evidence_archive_matches?(
            archive,
            view_name: view_name,
            action: action,
            actor: actor,
            export_id: export_id,
            content_hash: content_hash,
            privacy: privacy,
            status: status,
            meaning_status: meaning_status
          )
        end
        limit ? filtered.first(limit) : filtered
      end

      # Summarize app-owned policy/capability checks for a command plan.
      # This is metadata-only and never mutates storage or evaluates in Ledger.
      def command_policy_decision(plan, actor: nil, capabilities: [],
                                  approvals: [], metadata: {}, policy: nil)
        unless plan.is_a?(CommandOperationPlan)
          raise ArgumentError, "command_policy_decision expects Igniter::DurableModel::CommandOperationPlan"
        end

        base_policy = policy_for_plan(plan)
        merged_policy = merge_policy(base_policy, policy)
        required = Array(merged_policy[:requires]).map { |value| token(value) }
        granted = Array(capabilities).map { |value| token(value) }
        missing = required - granted
        review = !!merged_policy[:review]
        errors = Array(plan.errors)
        warnings = Array(plan.warnings)

        status = if !plan.ready?
          :denied
        elsif missing.any?
          errors += [plan_error(:missing_capabilities,
            "Missing required command capabilities: #{missing.inspect}")]
          :denied
        elsif review && !approval_matches?(plan, approvals)
          warnings += [plan_error(:review_required,
            "Command requires app-local review approval")]
          :review_required
        else
          :allowed
        end

        CommandPolicyDecision.new(
          status: status,
          owner: plan.owner,
          command: plan.command,
          subject_key: plan.subject_key,
          operation: plan.operation,
          actor: actor,
          required_capabilities: required,
          granted_capabilities: granted,
          missing_capabilities: missing,
          review_required: review,
          errors: errors,
          warnings: warnings,
          metadata: metadata
        )
      end

      # Register a projection descriptor — metadata-only, no execution.
      # Records which stores and relations a cross-record projection reads,
      # making this visible to the store engine via SchemaGraph.
      def register_projection(name, reads:, relations: [], consumer_hint: :contract_node, reactive: false)
        projection = projection_snapshot_entry(
          name: name,
          reads: Array(reads).map(&:to_sym),
          relations: Array(relations).map(&:to_sym),
          consumer_hint: consumer_hint,
          reactive: reactive
        )
        @projections_by_name[name.to_sym] = projection

        if client_backed?
          @inner.register_descriptor(
            schema_version: 1,
            kind:           :projection,
            name:           name,
            reads:          projection[:reads],
            relations:      projection[:relations],
            consumer_hint:  projection[:consumer_hint],
            reactive:       projection[:reactive]
          )
          return self
        end

        @inner.register_projection(
          Igniter::Store::ProjectionPath.new(
            name:          name,
            reads:         projection[:reads],
            relations:     projection[:relations],
            consumer_hint: projection[:consumer_hint],
            reactive:      projection[:reactive]
          )
        )
        self
      end

      # Returns a compact snapshot of all registered projection descriptors.
      def _projections
        if client_backed?
          remote = normalize_projection_snapshot(metadata_snapshot[:projections])
          return remote unless remote.empty?

          return @projections_by_name.dup
        end

        @inner.schema_graph.projection_snapshot
      end

      # Causation chain for a Record key — useful for debugging mutations.
      def causation_chain(schema_class, key:)
        @inner.causation_chain(store: schema_class.store_name, key: key)
      end

      # Read-only provenance summary for a Record key.
      def lineage(schema_class, key:)
        @inner.lineage(store: schema_class.store_name, key: key)
      end

      # Returns the unified OP2 metadata snapshot including all schemas registered
      # through Durable Model (stores, histories, access_paths, relations, etc.).
      def metadata_snapshot
        @inner.protocol.metadata_snapshot
      end

      # Returns raw store/history/subscription descriptor packets registered
      # through the Durable Model protocol surface.
      def descriptor_snapshot
        @inner.protocol.descriptor_snapshot
      end

      def close
        @inner.close
      end

      private

      ClientFact = Struct.new(:id, :store, :key, :value, :transaction_time, :valid_time, :value_hash, keyword_init: true) do
        def timestamp = transaction_time
      end

      class ClientAdapter
        attr_reader :client

        def initialize(client)
          @client = Igniter::LedgerClient.wrap(client)
        end

        def register_descriptor(descriptor)
          client.register_descriptor(descriptor)
        end

        def write(...)
          client.write(...)
        end

        def read(...)
          client.read(...)
        end

        def query(...)
          client.query(...)
        end

        def append(...)
          client.append(...)
        end

        def resolve(...)
          client.resolve(...)
        end

        def causation_chain(store:, key:)
          client.causation_chain(store: store, key: key).chain
        end

        def lineage(store:, key:)
          client.lineage(store: store, key: key).to_h
        end

        def subscribe(...)
          client.subscribe(...)
        end

        def history(store:, key: nil, since: nil, as_of: nil)
          client.replay(store: store, key: key, from: since, to: as_of).facts.map { |fact| normalize_fact(fact) }
        end

        def history_partition(store:, partition_key:, partition_value:, since: nil, as_of: nil)
          client.replay(
            store: store,
            partition_key: partition_key,
            partition_value: partition_value,
            from: since,
            to: as_of
          ).facts.map { |fact| normalize_fact(fact) }
        end

        def metadata_snapshot
          client.metadata_snapshot
        end

        def descriptor_snapshot
          client.descriptor_snapshot
        end

        def protocol
          self
        end

        def close
          client.close
        end

        private

        def normalize_fact(fact)
          data = fact.to_h.transform_keys(&:to_sym)
          ClientFact.new(
            id: data[:id],
            store: token(data[:store]),
            key: data[:key],
            value: normalize_value(data[:value] || {}),
            transaction_time: data[:transaction_time] || data[:timestamp],
            valid_time: data[:valid_time],
            value_hash: data[:value_hash]
          )
        end

        def normalize_value(value)
          return value unless value.is_a?(Hash)

          value.each_with_object({}) { |(key, entry), acc| acc[key.to_sym] = entry }
        end

        def token(value)
          value.is_a?(String) ? value.to_sym : value
        end
      end

      def client_backed?
        @inner.is_a?(ClientAdapter)
      end

      def unsupported_client_mode!(feature)
        NotImplementedError.new("client-backed Durable Model store does not support #{feature} in v0")
      end

      def projection_snapshot_entry(name:, reads:, relations:, consumer_hint:, reactive:)
        {
          name: name.to_sym,
          reads: reads,
          relations: relations,
          consumer_hint: consumer_hint.to_sym,
          reactive: !!reactive,
          store_count: reads.size,
          relation_count: relations.size
        }
      end

      def normalize_projection_snapshot(snapshot)
        return {} unless snapshot

        snapshot.to_h.each_with_object({}) do |(name, raw), acc|
          data = raw.to_h.transform_keys(&:to_sym)
          reads = Array(data[:reads]).map(&:to_sym)
          relations = Array(data[:relations]).map(&:to_sym)
          acc[name.to_sym] = projection_snapshot_entry(
            name: data[:name] || name,
            reads: reads,
            relations: relations,
            consumer_hint: data[:consumer_hint] || :protocol_client,
            reactive: data[:reactive]
          )
        end
      end

      def normalize_scatter_snapshot(snapshot)
        Array(snapshot).map do |raw|
          data = raw.to_h.transform_keys(&:to_sym)
          {
            index: data[:index],
            source_store: token(data[:source_store]),
            partition_by: token(data[:partition_by]),
            target_store: token(data[:target_store]),
            has_rule: data.fetch(:has_rule, true)
          }.compact
        end
      end

      def normalize_value(value)
        return value unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, entry), acc| acc[token(key)] = entry }
      end

      def token(value)
        value.is_a?(String) ? value.to_sym : value
      end

      def result_fact_id(result)
        result.respond_to?(:fact_id) ? result.fact_id : result.id
      end

      def result_value_hash(result)
        result.respond_to?(:value_hash) ? result.value_hash : result.value_hash
      end

      def result_causation(result)
        result.respond_to?(:causation) ? result.causation : nil
      end

      def result_key(result, fallback:)
        result.respond_to?(:key) && result.key ? result.key : fallback
      end

      def result_timestamp(result)
        if result.respond_to?(:timestamp)
          result.timestamp
        elsif result.respond_to?(:transaction_time)
          result.transaction_time
        end
      end

      def emit_companion_descriptor(schema_class)
        if schema_class.respond_to?(:_scopes)
          emit_store_descriptor(schema_class)
          emit_command_descriptors(schema_class)
          emit_effect_descriptors(schema_class)
        else
          emit_history_descriptor(schema_class)
        end
      end

      def emit_store_descriptor(schema_class)
        key = if schema_class.respond_to?(:_fields) && schema_class._fields.key?(:id)
          :id
        elsif schema_class.respond_to?(:_fields)
          schema_class._fields.keys.first || :id
        else
          :id
        end

        fields = if schema_class.respond_to?(:_fields)
          schema_class._fields.map do |name, attrs|
            h = { name: name }
            h[:type]    = attrs[:type]    if attrs[:type]
            h[:default] = attrs[:default] unless attrs[:default].nil?
            h[:values]  = attrs[:values]  if attrs[:values]
            h
          end
        else
          []
        end

        @inner.register_descriptor({
          schema_version: 1,
          kind:           :store,
          name:           schema_class.store_name,
          key:            key,
          fields:         fields,
          capabilities:   %i[write current_read as_of_read],
          producer:       { system: :igniter_companion, name: schema_class.name.to_s }
        })
      end

      def emit_history_descriptor(schema_class)
        pk = schema_class.respond_to?(:_partition_key) ? schema_class._partition_key : :id

        @inner.register_descriptor({
          schema_version: 1,
          kind:           :history,
          name:           schema_class.store_name,
          key:            pk || :id,
          producer:       { system: :igniter_companion, name: schema_class.name.to_s }
        })
      end

      def emit_command_descriptors(schema_class)
        return unless schema_class.respond_to?(:_commands)

        schema_class._commands.each do |command_name, attrs|
          descriptor = command_descriptor(schema_class, command_name, attrs)
          @inner.register_descriptor(descriptor)
        end
      end

      def emit_effect_descriptors(schema_class)
        return unless schema_class.respond_to?(:_effects)

        schema_class._effects.each do |command_name, attrs|
          descriptor = effect_descriptor(schema_class, command_name, attrs)
          @inner.register_descriptor(descriptor)
        end
      end

      def command_descriptor(schema_class, command_name, attrs)
        data = attrs.to_h.transform_keys(&:to_sym)
        operation = token(data[:operation] || :none)
        policy = normalized_command_policy(data)
        descriptor = data.merge(
          schema_version: 1,
          kind:           :command,
          name:           command_name,
          owner:          schema_class.store_name,
          operation:      operation,
          target_shape:   data[:target_shape] || target_shape_for(operation),
          boundary:       data[:boundary] || :app,
          mutation_intent: data[:mutation_intent] || operation
        )
        descriptor[:changes] = data[:changes] if data.key?(:changes)
        descriptor[:policy] = policy if policy
        descriptor
      end

      def effect_descriptor(schema_class, command_name, attrs)
        data = attrs.to_h.transform_keys(&:to_sym)
        data.merge(
          schema_version: 1,
          kind:           :effect,
          name:           command_name,
          owner:          schema_class.store_name,
          store_op:       data[:store_op] || :none,
          write_kind:     data[:write_kind] || :none,
          lowers_to:      data[:lowers_to] || :none,
          boundary:       data[:boundary] || :app
        )
      end

      def target_shape_for(operation)
        case operation
        when :record_append, :record_update
          :store
        when :history_append
          :history
        else
          :none
        end
      end

      def normalize_command_snapshot(snapshot)
        normalize_descriptor_snapshot(snapshot) do |data|
          {
            name: token(data[:name]),
            owner: token(data[:owner]),
            operation: token(data[:operation]),
            target_shape: token(data[:target_shape]),
            boundary: token(data[:boundary]),
            mutation_intent: token(data[:mutation_intent]),
            changes: normalize_value(data[:changes] || {}),
            policy: normalized_command_policy(data)
          }.compact
        end
      end

      def normalize_effect_snapshot(snapshot)
        normalize_descriptor_snapshot(snapshot) do |data|
          {
            name: token(data[:name]),
            owner: token(data[:owner]),
            store_op: token(data[:store_op]),
            write_kind: token(data[:write_kind]),
            lowers_to: token(data[:lowers_to]),
            boundary: token(data[:boundary]),
            source_operation: token(data[:source_operation])
          }.compact
        end
      end

      def normalize_descriptor_snapshot(snapshot)
        return {} unless snapshot

        snapshot.to_h.each_with_object({}) do |(owner, entries), acc|
          acc[token(owner)] = entries.to_h.each_with_object({}) do |(name, raw), owner_acc|
            data = raw.to_h.transform_keys(&:to_sym)
            owner_acc[token(name)] = yield(data)
          end
        end
      end

      def command_attrs_for(schema_class, command_key)
        unless schema_class.respond_to?(:_commands)
          raise ArgumentError, "#{schema_class} does not declare commands"
        end

        attrs = descriptor_entry(schema_class._commands, command_key)
        return attrs.to_h.transform_keys(&:to_sym) if attrs

        raise ArgumentError,
              "Unknown command #{command_key.inspect} for store=#{schema_class.store_name.inspect}"
      end

      def effect_attrs_for(schema_class, command_key)
        command_attrs = command_attrs_for(schema_class, command_key)
        return none_effect(command_attrs[:operation]) unless schema_class.respond_to?(:_effects)

        attrs = descriptor_entry(schema_class._effects, command_key)
        return attrs.to_h.transform_keys(&:to_sym) if attrs

        none_effect(command_attrs[:operation])
      end

      def none_effect(operation)
        {
          store_op: :none,
          write_kind: :none,
          lowers_to: :none,
          source_operation: token(operation || :none)
        }
      end

      def intent_effect(effect_attrs)
        {
          store_op: token(effect_attrs[:store_op] || :none),
          write_kind: token(effect_attrs[:write_kind] || :none),
          lowers_to: token(effect_attrs[:lowers_to] || :none),
          source_operation: token(effect_attrs[:source_operation])
        }.compact
      end

      def descriptor_entry(entries, key)
        entries[key] || entries[key.to_s]
      end

      def plan_record_update(intent)
        return plan_missing_key(intent) if intent.subject_key.nil?

        schema_class = schema_for_intent(intent)
        return plan_missing_schema(intent) unless schema_class

        record = read(schema_class, key: intent.subject_key)
        unless record
          return build_command_plan(intent,
            status: :invalid,
            target: store_target(intent),
            errors: [plan_error(:record_not_found,
              "No record found for owner=#{intent.owner.inspect} key=#{intent.subject_key.inspect}")])
        end

        value = record.to_h
          .merge(intent.changes)
          .merge(plan_hash_param(intent, :changes))
        build_command_plan(intent,
          status: :ready,
          target: store_target(intent),
          value: value)
      end

      def plan_record_append(intent)
        schema_class = schema_for_intent(intent)
        return plan_missing_schema(intent) unless schema_class

        value = intent.changes.merge(plan_hash_param(intent, :attributes))
        build_command_plan(intent,
          status: :ready,
          target: store_target(intent),
          value: value)
      end

      def plan_history_append(intent)
        history_name, warnings = history_target_for(intent)
        event = plan_event(intent)
        build_command_plan(intent,
          status: :ready,
          target: { shape: :history, name: history_name, key: nil },
          event: event,
          warnings: warnings)
      end

      def plan_missing_key(intent)
        build_command_plan(intent,
          status: :invalid,
          target: store_target(intent),
          errors: [plan_error(:missing_key,
            "record_update command plan requires subject_key")])
      end

      def plan_missing_schema(intent)
        build_command_plan(intent,
          status: :invalid,
          target: { shape: intent.target_shape, name: intent.owner, key: intent.subject_key },
          errors: [plan_error(:schema_not_registered,
            "No schema registered for owner=#{intent.owner.inspect}")])
      end

      def build_command_plan(intent, status:, target:, value: nil, event: nil,
                             errors: [], warnings: [])
        CommandOperationPlan.new(
          owner: intent.owner,
          command: intent.command,
          subject_key: intent.subject_key,
          operation: intent.operation,
          status: status,
          target: target,
          value: value,
          event: event,
          effect: intent.effect,
          errors: errors,
          warnings: warnings,
          metadata: intent.metadata
        )
      end

      def store_target(intent)
        { shape: :store, name: intent.owner, key: intent.subject_key }
      end

      def schema_for_intent(intent)
        @schema_by_store[token(intent.owner)]
      end

      def plan_hash_param(intent, key)
        value = intent.params[key]
        value.is_a?(Hash) ? value : {}
      end

      def history_target_for(intent)
        event = intent.event.is_a?(Hash) ? intent.event : {}
        explicit = intent.metadata[:history] || intent.metadata[:history_name] ||
                   intent.metadata[:target_history] || event[:history] ||
                   event[:history_name]
        return [token(explicit), []] if explicit

        [intent.owner, [plan_error(:history_target_inferred,
          "No explicit history target; using owner=#{intent.owner.inspect}")]]
      end

      def plan_event(intent)
        base = intent.event.is_a?(Hash) ? intent.event : {}
        base.merge(intent.params)
      end

      def plan_error(code, message)
        { code: code, message: message }
      end

      def activity_from_intent(intent, status:, metadata:)
        CommandActivityEvent.new(
          owner: intent.owner,
          command: intent.command,
          subject_key: intent.subject_key,
          operation: intent.operation,
          status: status || :intended,
          intent_status: :ready,
          plan_status: nil,
          target: nil,
          errors: [],
          warnings: [],
          metadata: merged_metadata(intent.metadata, metadata)
        )
      end

      def activity_from_plan(plan, status:, metadata:)
        CommandActivityEvent.new(
          owner: plan.owner,
          command: plan.command,
          subject_key: plan.subject_key,
          operation: plan.operation,
          status: status || (plan.ready? ? :planned : :rejected),
          intent_status: :ready,
          plan_status: plan.status,
          target: plan.target,
          errors: plan.errors,
          warnings: plan.warnings,
          metadata: merged_metadata(plan.metadata, metadata)
        )
      end

      def merged_metadata(source_metadata, explicit_metadata)
        normalize_value(source_metadata || {}).merge(normalize_value(explicit_metadata || {}))
      end

      def command_activity_payload(event)
        {
          owner: event.owner,
          command: event.command,
          subject_key: event.subject_key,
          operation: event.operation,
          status: event.status,
          intent_status: event.intent_status,
          plan_status: event.plan_status,
          target: event.target,
          errors: event.errors,
          warnings: event.warnings,
          metadata: event.metadata,
          store_fact_exposed: event.store_fact_exposed,
          value_hash_exposed: event.value_hash_exposed,
          execution_allowed: event.execution_allowed
        }
      end

      def command_flow_slice_filters(command:, subject_key:, request_id:,
                                     actor:, status:)
        {
          command: command.nil? ? nil : token(command),
          subject_key: subject_key,
          request_id: request_id,
          actor: actor,
          status: status.nil? ? nil : token(status)
        }.compact
      end

      def filter_command_flow_slice_events(events, command:, subject_key:,
                                           request_id:, actor:)
        events.select do |event|
          command_matches = command.nil? || event.command == token(command)
          subject_matches = subject_key.nil? || event.subject_key == subject_key
          request_matches = request_id.nil? || event.metadata[:request_id] == request_id
          actor_matches = actor.nil? || event.metadata[:actor] == actor

          command_matches && subject_matches && request_matches && actor_matches
        end
      end

      def command_flow_slice_items(events, owner:, status:)
        grouped_events = command_flow_slice_groups(events)
        items = grouped_events.map do |_group_key, group_events|
          lifecycle = build_command_lifecycle(group_events,
            owner: owner,
            command: group_events.last.command,
            subject_key: group_events.last.subject_key,
            request_id: group_events.last.metadata[:request_id])
          command_flow_slice_item(lifecycle, group_events)
        end
        filtered_items = if status
          items.select { |item| item[:status] == token(status) }
        else
          items
        end
        filtered_items.sort_by { |item| [item[:last_seen_at] || 0, item[:request_id].to_s] }
      end

      def command_flow_slice_groups(events)
        groups = {}
        events.each_with_index do |event, index|
          key = event.metadata[:request_id]
          group_key = if key
            [:request_id, key]
          else
            [:activity, event.owner, event.command, event.subject_key, event.timestamp || index]
          end
          groups[group_key] ||= []
          groups[group_key] << event
        end
        groups
      end

      def command_flow_slice_item(lifecycle, events)
        first = events.first
        last = events.last
        {
          owner: lifecycle.owner,
          command: lifecycle.command,
          subject_key: lifecycle.subject_key,
          request_id: lifecycle.request_id,
          actor: lifecycle.actor,
          status: lifecycle.status,
          intent_status: lifecycle.intent_status,
          plan_status: lifecycle.plan_status,
          policy_status: lifecycle.policy_status,
          apply_status: lifecycle.apply_status,
          operation: lifecycle.operation,
          target: lifecycle.target,
          first_seen_at: first.timestamp,
          last_seen_at: last.timestamp,
          activity_count: events.size,
          errors: lifecycle.errors,
          warnings: lifecycle.warnings,
          metadata: lifecycle.metadata
        }
      end

      def temporal_value(value)
        return nil if value.nil?

        value.respond_to?(:to_f) ? value.to_f : value
      end

      MONITOR_METRICS = %i[
        total status_count status_ratio command_count actor_count
        subject_count request_count
      ].freeze

      MONITOR_OPERATORS = %i[> >= < <= == !=].freeze

      MONITOR_SEVERITIES = %i[info warning critical].freeze

      def normalize_monitor_rule(rule)
        data = normalize_value(rule || {})
        metric = token(data[:metric])
        op = token(data[:op])
        severity = token(data[:severity] || :warning)

        raise ArgumentError, "Unknown command_flow_monitor metric: #{metric.inspect}" unless MONITOR_METRICS.include?(metric)
        raise ArgumentError, "Unknown command_flow_monitor operator: #{op.inspect}" unless MONITOR_OPERATORS.include?(op)
        raise ArgumentError, "Unknown command_flow_monitor severity: #{severity.inspect}" unless MONITOR_SEVERITIES.include?(severity)
        raise ArgumentError, "command_flow_monitor rule requires name" unless data[:name]
        raise ArgumentError, "command_flow_monitor rule requires value" unless data.key?(:value)

        {
          name: token(data[:name]),
          metric: metric,
          op: op,
          value: data[:value],
          status: data.key?(:status) ? token(data[:status]) : nil,
          command: data.key?(:command) ? token(data[:command]) : nil,
          actor: data[:actor],
          severity: severity,
          message: data[:message],
          metadata: normalize_value(data[:metadata] || {})
        }.compact
      end

      def command_flow_monitor_observation(rule, slice)
        actual = command_flow_monitor_metric(rule, slice)
        matched = command_flow_monitor_compare(actual, rule[:op], rule[:value])
        {
          name: rule[:name],
          metric: rule[:metric],
          op: rule[:op],
          expected: rule[:value],
          actual: actual,
          matched: matched,
          severity: rule[:severity],
          message: rule[:message],
          metadata: rule[:metadata]
        }.compact
      end

      def command_flow_monitor_metric(rule, slice)
        case rule[:metric]
        when :total
          slice.size
        when :status_count
          slice.status_counts.fetch(required_monitor_rule_field(rule, :status), 0)
        when :status_ratio
          return 0.0 if slice.size.zero?

          slice.status_counts.fetch(required_monitor_rule_field(rule, :status), 0).to_f / slice.size
        when :command_count
          slice.command_counts.fetch(required_monitor_rule_field(rule, :command), 0)
        when :actor_count
          slice.actor_counts.fetch(required_monitor_rule_field(rule, :actor), 0)
        when :subject_count
          slice.subject_count
        when :request_count
          slice.request_count
        else
          raise ArgumentError, "Unknown command_flow_monitor metric: #{rule[:metric].inspect}"
        end
      end

      def required_monitor_rule_field(rule, key)
        return rule[key] if rule.key?(key)

        raise ArgumentError,
              "command_flow_monitor metric=#{rule[:metric].inspect} requires #{key}:"
      end

      def command_flow_monitor_compare(actual, op, expected)
        case op
        when :> then actual > expected
        when :>= then actual >= expected
        when :< then actual < expected
        when :<= then actual <= expected
        when :== then actual == expected
        when :!= then actual != expected
        else
          raise ArgumentError, "Unknown command_flow_monitor operator: #{op.inspect}"
        end
      end

      def command_flow_monitor_status(alerts)
        return :critical if alerts.any? { |alert| alert[:severity] == :critical }
        return :warning if alerts.any? { |alert| alert[:severity] == :warning }

        :ok
      end

      def command_flow_view_descriptor(name)
        descriptor = @command_flow_views[token(name)]
        raise ArgumentError, "Unknown command flow view: #{name.inspect}" unless descriptor

        descriptor
      end

      def build_command_flow_view(descriptor, since:, as_of:, limit:,
                                  overrides:, history_class:, horizon:)
        filters = descriptor.filters.merge(normalize_value(overrides || {}))
        resolved_as_of = as_of.nil? ? command_flow_view_as_of(horizon) : as_of
        slice = command_flow_slice(
          owner: descriptor.owner,
          command: filters[:command],
          subject_key: filters[:subject_key],
          request_id: filters[:request_id],
          actor: filters[:actor],
          status: filters[:status],
          since: since,
          as_of: resolved_as_of,
          limit: limit,
          history_class: history_class
        )
        monitor = command_flow_monitor(
          owner: descriptor.owner,
          name: descriptor.name,
          rules: descriptor.rules,
          slice: slice
        )
        CommandFlowView.new(
          name: descriptor.name,
          owner: descriptor.owner,
          status: monitor.status,
          mode: horizon[:mode],
          horizon: horizon,
          filters: filters,
          action_policy: descriptor.action_policy,
          slice: slice,
          monitor: monitor,
          summary: monitor.summary
        )
      end

      def pinned_command_flow_view_horizon(descriptor, as_of)
        horizon = normalize_command_flow_view_horizon(descriptor.horizon)
        rule_version = horizon[:rule_version]
        rule_version = :current_rules if rule_version.nil? || rule_version == :latest
        fact_scope = horizon[:fact_scope] || {
          history: :command_activity,
          owner: descriptor.owner
        }

        horizon.merge(
          mode: :reproducible,
          as_of: as_of,
          rule_version: rule_version,
          fact_scope: fact_scope
        )
      end

      def command_flow_view_missing_capabilities(action_policy, capabilities)
        required = Array(action_policy[:required_capabilities]).map do |value|
          token(value)
        end
        required - capabilities
      end

      def command_flow_view_pin_errors(view, action, missing_capabilities)
        decision = view.action_policy[action]
        errors = []
        if decision.nil?
          errors << command_flow_view_pin_error(
            :unknown_view_action,
            "Unknown command flow view action: #{action.inspect}"
          )
        elsif decision == false || token(decision) == :forbidden
          errors << command_flow_view_pin_error(
            :action_forbidden,
            "Command flow view action is forbidden: #{action.inspect}"
          )
        end
        if missing_capabilities.any?
          errors << command_flow_view_pin_error(
            :missing_capabilities,
            "Command flow view action is missing required capabilities",
            capabilities: missing_capabilities
          )
        end
        if token(decision) == :requires_pinned_horizon && !view.reproducible?
          errors << command_flow_view_pin_error(
            :pinned_horizon_required,
            "Command flow view action requires a pinned horizon"
          )
        end

        errors
      end

      def command_flow_view_pin_error(code, message, **metadata)
        {
          code: code,
          message: message,
          metadata: normalize_value(metadata)
        }
      end

      def command_flow_view_pin_meaning_status(horizon, allowed)
        return :reproducible if allowed && horizon[:mode] == :reproducible && horizon[:fact_scope]
        return :live if horizon[:mode] == :live

        :unknown
      end

      def command_flow_view_pin_receipt(view, action:, actor:, status:,
                                        meaning_status:, horizon:,
                                        capabilities:, missing_capabilities:,
                                        metadata:, generated_at:)
        {
          kind: :command_flow_view_pin_receipt,
          receipt_id: "cfvp_#{SecureRandom.hex(8)}",
          view_name: view.name,
          owner: view.owner,
          action: action,
          actor: actor,
          status: status,
          meaning_status: meaning_status,
          horizon: horizon,
          capabilities: capabilities,
          missing_capabilities: missing_capabilities,
          view_status: view.status,
          monitor_status: view.monitor.status,
          summary: view.summary,
          generated_at: generated_at,
          metadata: metadata
        }
      end

      def command_flow_decision_payload(pin, decision_receipt_id:, metadata:)
        {
          owner: pin.owner,
          view_name: pin.name,
          action: pin.action,
          actor: pin.actor,
          status: pin.status,
          meaning_status: pin.meaning_status,
          receipt_id: pin.receipt[:receipt_id],
          decision_receipt_id: decision_receipt_id,
          horizon: pin.horizon,
          capabilities: pin.capabilities,
          missing_capabilities: pin.missing_capabilities,
          view_status: pin.view&.status,
          monitor_status: pin.view&.monitor&.status,
          summary: pin.view&.summary || {},
          errors: pin.errors,
          warnings: pin.warnings,
          metadata: metadata,
          store_fact_exposed: pin.store_fact_exposed,
          value_hash_exposed: pin.value_hash_exposed
        }
      end

      def command_flow_decision_metadata(pin, metadata)
        pin.metadata.merge(normalize_value(metadata || {}))
      end

      def command_flow_decision_matches?(decision, view_name:, action:, actor:,
                                         status:, meaning_status:, receipt_id:,
                                         decision_receipt_id:)
        view_matches = view_name.nil? || decision.view_name == token(view_name)
        action_matches = action.nil? || decision.action == token(action)
        actor_matches = actor.nil? || decision.actor == actor
        status_matches = status.nil? || decision.status == token(status)
        meaning_matches = meaning_status.nil? ||
                          decision.meaning_status == token(meaning_status)
        receipt_matches = receipt_id.nil? || decision.receipt_id == receipt_id
        decision_receipt_matches = decision_receipt_id.nil? ||
                                   decision.decision_receipt_id == decision_receipt_id

        view_matches && action_matches && actor_matches && status_matches &&
          meaning_matches && receipt_matches && decision_receipt_matches
      end

      REVIEW_METRICS = %i[
        total status_count meaning_status_count view_count action_count
        actor_count missing_capability_count error_count warning_count
      ].freeze

      def command_flow_decision_review_filters(view_name:, action:, actor:,
                                               status:, meaning_status:,
                                               receipt_id:,
                                               decision_receipt_id:)
        {
          view_name: token(view_name),
          action: token(action),
          actor: actor,
          status: token(status),
          meaning_status: token(meaning_status),
          receipt_id: receipt_id,
          decision_receipt_id: decision_receipt_id
        }.compact
      end

      def command_flow_decision_review_summary(decisions)
        generated_values = decisions.map(&:timestamp).compact
        {
          total: decisions.size,
          status_count: count_by(decisions.map(&:status)),
          meaning_status_count: count_by(decisions.map(&:meaning_status)),
          view_count: count_by(decisions.map(&:view_name)),
          action_count: count_by(decisions.map(&:action)),
          actor_count: count_by(decisions.map(&:actor).compact),
          missing_capability_count: decisions.sum { |decision| Array(decision.missing_capabilities).size },
          error_count: decisions.sum { |decision| Array(decision.errors).size },
          warning_count: decisions.sum { |decision| Array(decision.warnings).size },
          latest_generated_at: generated_values.max
        }
      end

      def count_by(values)
        values.each_with_object(Hash.new(0)) do |value, counts|
          counts[value] += 1
        end.to_h
      end

      def normalize_decision_review_rule(rule)
        data = normalize_value(rule || {})
        metric = token(data[:metric])
        op = token(data[:op])
        severity = token(data[:severity] || :warning)

        unless REVIEW_METRICS.include?(metric)
          raise ArgumentError, "Unknown command_flow_decision_review metric: #{metric.inspect}"
        end
        unless MONITOR_OPERATORS.include?(op)
          raise ArgumentError, "Unknown command_flow_decision_review operator: #{op.inspect}"
        end
        unless MONITOR_SEVERITIES.include?(severity)
          raise ArgumentError, "Unknown command_flow_decision_review severity: #{severity.inspect}"
        end
        raise ArgumentError, "command_flow_decision_review rule requires name" unless data[:name]
        raise ArgumentError, "command_flow_decision_review rule requires value" unless data.key?(:value)

        data.merge(
          name: token(data[:name]),
          metric: metric,
          op: op,
          severity: severity,
          status: token(data[:status]),
          meaning_status: token(data[:meaning_status]),
          view_name: token(data[:view_name]),
          action: token(data[:action])
        ).compact
      end

      def command_flow_decision_review_finding(rule, summary)
        actual = command_flow_decision_review_metric(rule, summary)
        return nil unless command_flow_monitor_compare(actual, rule[:op], rule[:value])

        {
          name: rule[:name],
          status: :matched,
          severity: rule[:severity],
          metric: rule[:metric],
          expected: rule[:value],
          actual: actual,
          message: rule[:message]
        }.compact
      end

      def command_flow_decision_review_metric(rule, summary)
        case rule[:metric]
        when :total
          summary[:total]
        when :status_count
          summary[:status_count].fetch(required_decision_review_rule_field(rule, :status), 0)
        when :meaning_status_count
          summary[:meaning_status_count].fetch(required_decision_review_rule_field(rule, :meaning_status), 0)
        when :view_count
          summary[:view_count].fetch(required_decision_review_rule_field(rule, :view_name), 0)
        when :action_count
          summary[:action_count].fetch(required_decision_review_rule_field(rule, :action), 0)
        when :actor_count
          summary[:actor_count].fetch(required_decision_review_rule_field(rule, :actor), 0)
        when :missing_capability_count
          summary[:missing_capability_count]
        when :error_count
          summary[:error_count]
        when :warning_count
          summary[:warning_count]
        else
          raise ArgumentError, "Unknown command_flow_decision_review metric: #{rule[:metric].inspect}"
        end
      end

      def required_decision_review_rule_field(rule, key)
        return rule[key] if rule.key?(key)

        raise ArgumentError,
              "command_flow_decision_review metric=#{rule[:metric].inspect} requires #{key}:"
      end

      def command_flow_decision_review_status(findings)
        return :critical if findings.any? { |finding| finding[:severity] == :critical }
        return :warning if findings.any? { |finding| finding[:severity] == :warning }

        :ok
      end

      def command_flow_evidence_profile_status(view, pin, review)
        return :critical if review.critical?
        return :blocked if pin&.blocked?
        return :warning if review.warning? || view.warning? || view.monitor.warning?

        :ok
      end

      def command_flow_evidence_profile_meaning_status(view, pin, review)
        meanings = review.decisions.map { |decision| token(decision[:meaning_status]) }.compact.uniq
        return :unknown if pin&.blocked?
        return :unknown if meanings.include?(:unknown) || meanings.include?(:provisional)
        return :mixed if meanings.size > 1
        return :reproducible if pin&.reproducible? || (pin.nil? && view.reproducible?)
        return :live if view.live?

        :unknown
      end

      def command_flow_evidence_profile_horizon(view, pin, review)
        {
          view: view.horizon,
          pin: pin&.horizon,
          review: review.horizon
        }.compact
      end

      def command_flow_evidence_profile_links(owner:, view_name:, pin:, review:)
        view_ref = command_flow_evidence_ref(:view, view_name)
        links = [{
          rel: :derived_from,
          from: view_ref,
          to: command_flow_evidence_ref(:owner, owner)
        }, {
          rel: :reviews,
          from: command_flow_evidence_ref(:decision_review, "#{owner}/#{view_name}"),
          to: view_ref
        }]
        if pin
          links << {
            rel: :pins,
            from: command_flow_evidence_ref(:pin, pin.receipt[:receipt_id]),
            to: view_ref
          }
        end
        review.decisions.each do |decision|
          decision_ref = command_flow_decision_evidence_ref(decision)
          links << {
            rel: :derived_from,
            from: decision_ref,
            to: command_flow_evidence_ref(:pin, decision[:receipt_id])
          } if decision[:receipt_id]
          links << {
            rel: :identified_by,
            from: decision_ref,
            to: command_flow_evidence_ref(:decision_receipt, decision[:decision_receipt_id])
          } if decision[:decision_receipt_id]
        end
        links
      end

      def command_flow_evidence_packets(view:, pin:, review:)
        packets = [
          command_flow_evidence_packet(
            kind: :command_flow_view_evidence,
            subject: command_flow_evidence_ref(:view, view.name),
            meaning_status: view.reproducible? ? :reproducible : :live,
            payload: view.to_h,
            links: [{
              rel: :derived_from,
              ref: command_flow_evidence_ref(:owner, view.owner)
            }]
          )
        ]
        if pin
          packets << command_flow_evidence_packet(
            kind: :command_flow_pin_evidence,
            subject: command_flow_evidence_ref(:pin, pin.receipt[:receipt_id]),
            meaning_status: pin.meaning_status,
            payload: pin.to_h,
            links: [{
              rel: :pins,
              ref: command_flow_evidence_ref(:view, pin.name)
            }]
          )
        end
        packets << command_flow_evidence_packet(
          kind: :command_flow_decision_review_evidence,
          subject: command_flow_evidence_ref(:decision_review, "#{review.owner}/#{review.filters[:view_name] || :all}"),
          meaning_status: review.meaning_status,
          payload: review.to_h,
          links: [{
            rel: :reviews,
            ref: command_flow_evidence_ref(:view, review.filters[:view_name] || :all)
          }]
        )
        review.decisions.each do |decision|
          packets << command_flow_evidence_packet(
            kind: :command_flow_decision_evidence,
            subject: command_flow_decision_evidence_ref(decision),
            meaning_status: decision[:meaning_status],
            payload: decision,
            links: command_flow_decision_packet_links(decision)
          )
        end
        packets
      end

      def command_flow_evidence_packet(kind:, subject:, meaning_status:, payload:, links:)
        {
          schema_version: 1,
          kind: kind,
          subject: subject,
          meaning_status: meaning_status,
          payload: payload,
          links: links,
          policy: {
            store_fact_exposed: false,
            value_hash_exposed: false
          }
        }
      end

      def command_flow_decision_packet_links(decision)
        links = []
        if decision[:receipt_id]
          links << {
            rel: :derived_from,
            ref: command_flow_evidence_ref(:pin, decision[:receipt_id])
          }
        end
        if decision[:decision_receipt_id]
          links << {
            rel: :identified_by,
            ref: command_flow_evidence_ref(:decision_receipt, decision[:decision_receipt_id])
          }
        end
        links
      end

      def command_flow_decision_evidence_ref(decision)
        id = decision[:decision_receipt_id] || decision[:receipt_id] || "unknown"
        command_flow_evidence_ref(:decision, id)
      end

      def command_flow_evidence_ref(kind, id)
        case kind
        when :owner
          "durable-model://command-flow/owners/#{id}"
        when :view
          "durable-model://command-flow/views/#{id}"
        when :pin
          "durable-model://command-flow/pins/#{id}"
        when :decision_review
          "durable-model://command-flow/decision-reviews/#{id}"
        when :decision_receipt
          "durable-model://command-flow/decision-receipts/#{id}"
        when :decision
          "durable-model://command-flow/decisions/#{id}"
        else
          "durable-model://command-flow/#{kind}/#{id}"
        end
      end

      EVIDENCE_EXPORT_PRIVACY = %i[app_safe summary_only hash_payloads].freeze

      def command_flow_evidence_export_payload(profile, privacy:, include_packets:,
                                               include_decisions:, metadata:)
        policy = token(privacy)
        unless EVIDENCE_EXPORT_PRIVACY.include?(policy)
          raise ArgumentError, "Unknown command_flow_evidence_export privacy: #{privacy.inspect}"
        end

        redactions = []
        export_profile = command_flow_evidence_export_profile(profile,
          privacy: policy,
          include_decisions: include_decisions,
          redactions: redactions)
        packets = command_flow_evidence_export_packets(profile,
          privacy: policy,
          include_packets: include_packets,
          redactions: redactions)
        diagnostics = command_flow_evidence_export_diagnostics(profile,
          privacy: policy,
          include_packets: include_packets,
          include_decisions: include_decisions)

        {
          schema_version: 1,
          kind: :command_flow_evidence_export_content,
          profile_kind: profile.kind,
          owner: profile.owner,
          view_name: profile.view_name,
          action: profile.action,
          actor: profile.actor,
          status: profile.status,
          meaning_status: profile.meaning_status,
          privacy: policy,
          generated_at: profile.generated_at,
          profile: export_profile,
          packets: packets,
          links: profile.links,
          diagnostics: diagnostics,
          redactions: redactions,
          metadata: normalize_value(metadata || {}),
          store_fact_exposed: false,
          value_hash_exposed: false
        }
      end

      def command_flow_evidence_export_profile(profile, privacy:, include_decisions:,
                                               redactions:)
        data = profile.to_h
        case privacy
        when :app_safe
          data = data.merge(decisions: command_flow_evidence_export_decisions(data[:decisions],
            include_decisions: include_decisions,
            redactions: redactions))
        when :summary_only
          data = command_flow_evidence_summary_profile(data)
          if profile.decisions.any?
            redactions << {
              path: [:profile, :decisions],
              action: :removed,
              count: profile.decisions.size
            }
          end
        when :hash_payloads
          data = command_flow_evidence_hash_profile_payloads(data, redactions)
          data = data.merge(decisions: command_flow_evidence_export_decisions(data[:decisions],
            include_decisions: include_decisions,
            redactions: redactions))
        end
        data
      end

      def command_flow_evidence_summary_profile(data)
        {
          schema_version: data[:schema_version],
          kind: data[:kind],
          owner: data[:owner],
          view_name: data[:view_name],
          action: data[:action],
          actor: data[:actor],
          status: data[:status],
          meaning_status: data[:meaning_status],
          generated_at: data[:generated_at],
          horizon: data[:horizon],
          review: {
            status: data.dig(:review, :status),
            meaning_status: data.dig(:review, :meaning_status),
            horizon: data.dig(:review, :horizon),
            summary: data.dig(:review, :summary),
            findings: data.dig(:review, :findings)
          },
          links: data[:links],
          metadata: data[:metadata],
          store_fact_exposed: data[:store_fact_exposed],
          value_hash_exposed: data[:value_hash_exposed]
        }
      end

      def command_flow_evidence_hash_profile_payloads(data, redactions)
        %i[view pin decisions].each do |key|
          next if data[key].nil? || (data[key].respond_to?(:empty?) && data[key].empty?)

          hash = command_flow_evidence_content_hash(data[key])
          data[key] = { content_hash: hash }
          redactions << {
            path: [:profile, key],
            action: :hashed,
            hash: hash
          }
        end
        data
      end

      def command_flow_evidence_export_decisions(decisions, include_decisions:, redactions:)
        return decisions if include_decisions

        count = Array(decisions).size
        redactions << {
          path: [:decisions],
          action: :removed,
          count: count
        } if count.positive?
        []
      end

      def command_flow_evidence_export_packets(profile, privacy:, include_packets:, redactions:)
        unless include_packets
          redactions << {
            path: [:packets],
            action: :removed,
            count: profile.packets.size
          } if profile.packets.any?
          return []
        end

        case privacy
        when :summary_only
          profile.packets.each_with_index.map do |packet, index|
            packet.reject { |key, _| key == :payload }.tap do
              redactions << {
                path: [:packets, index, :payload],
                action: :removed
              }
            end
          end
        when :hash_payloads
          profile.packets.each_with_index.map do |packet, index|
            next packet unless packet.key?(:payload)

            hash = command_flow_evidence_content_hash(packet[:payload])
            packet.merge(payload_hash: hash).reject { |key, _| key == :payload }.tap do
              redactions << {
                path: [:packets, index, :payload],
                action: :hashed,
                hash: hash
              }
            end
          end
        else
          profile.packets
        end
      end

      def command_flow_evidence_export_diagnostics(profile, privacy:,
                                                   include_packets:,
                                                   include_decisions:)
        diagnostics = []
        if profile.action && profile.pin.nil?
          diagnostics << command_flow_evidence_diagnostic(:evidence_pin_missing,
            :warning,
            "Profile action was supplied but no pin evidence is present")
        end
        if profile.pin && profile.pin[:status] == :blocked
          diagnostics << command_flow_evidence_diagnostic(:evidence_profile_blocked,
            :warning,
            "Profile includes a blocked pin")
        end
        if %i[unknown provisional mixed].include?(profile.meaning_status)
          diagnostics << command_flow_evidence_diagnostic(:evidence_meaning_incomplete,
            :info,
            "Profile meaning status is #{profile.meaning_status.inspect}")
        end
        if profile.review[:status] == :critical
          diagnostics << command_flow_evidence_diagnostic(:evidence_review_critical,
            :critical,
            "Profile includes a critical decision review")
        end
        if include_decisions && profile.review.dig(:summary, :total).to_i.zero?
          diagnostics << command_flow_evidence_diagnostic(:evidence_decisions_empty,
            :info,
            "Decision review contains no persisted decisions")
        end
        unless include_packets
          diagnostics << command_flow_evidence_diagnostic(:evidence_packets_omitted,
            :info,
            "Evidence packets were omitted by export options")
        end
        if privacy == :summary_only
          diagnostics << command_flow_evidence_diagnostic(:evidence_payloads_omitted,
            :info,
            "Detailed payloads were omitted by privacy policy")
        elsif privacy == :hash_payloads
          diagnostics << command_flow_evidence_diagnostic(:evidence_payloads_hashed,
            :info,
            "Detailed payloads were replaced with hashes")
        end
        diagnostics
      end

      def command_flow_evidence_diagnostic(code, severity, message)
        {
          code: code,
          severity: severity,
          message: message
        }
      end

      def command_flow_evidence_content_hash(value)
        Digest::SHA256.hexdigest(command_flow_evidence_canonical_json(value))
      end

      def command_flow_evidence_canonical_json(value)
        JSON.generate(command_flow_evidence_canonical_value(value))
      end

      def command_flow_evidence_canonical_value(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).each_with_object({}) do |key, acc|
            acc[key.to_s] = command_flow_evidence_canonical_value(value[key])
          end
        when Array
          value.map { |entry| command_flow_evidence_canonical_value(entry) }
        when Symbol
          value.to_s
        when Time
          value.utc.iso8601(6)
        else
          value
        end
      end

      def command_flow_evidence_verification(export_id:, expected_hash:,
                                             canonical_json:, privacy:,
                                             metadata:)
        actual_hash = Digest::SHA256.hexdigest(canonical_json.to_s)
        valid = actual_hash == expected_hash
        diagnostics = []
        unless valid
          diagnostics << {
            code: :evidence_export_hash_mismatch,
            severity: :critical,
            message: "Evidence export content hash does not match canonical JSON"
          }
        end

        CommandFlowEvidenceExportVerification.new(
          status: valid ? :valid : :invalid,
          export_id: export_id,
          expected_hash: expected_hash,
          actual_hash: actual_hash,
          privacy: privacy,
          diagnostics: diagnostics,
          metadata: metadata
        )
      end

      def command_flow_evidence_archive_payload(export, metadata:)
        {
          owner: export.owner,
          view_name: export.view_name,
          action: export.action,
          actor: export.actor,
          export_id: export.export_id,
          content_hash: export.content_hash,
          privacy: export.privacy,
          status: export.status,
          meaning_status: export.meaning_status,
          profile_kind: export.profile_kind,
          canonical_json: export.canonical_json,
          diagnostics: export.diagnostics,
          redactions: export.redactions,
          metadata: metadata,
          store_fact_exposed: export.store_fact_exposed,
          value_hash_exposed: export.value_hash_exposed
        }
      end

      def command_flow_evidence_archive_receipt(export, archive_receipt_id:,
                                                status:, diagnostics:,
                                                metadata:)
        CommandFlowEvidenceArchiveReceipt.new(
          archive_receipt_id: archive_receipt_id,
          export_id: export.export_id,
          content_hash: export.content_hash,
          owner: export.owner,
          view_name: export.view_name,
          privacy: export.privacy,
          meaning_status: export.meaning_status,
          status: status,
          diagnostics: diagnostics,
          metadata: metadata,
          store_fact_exposed: export.store_fact_exposed,
          value_hash_exposed: export.value_hash_exposed
        )
      end

      def command_flow_evidence_archive_matches?(archive, view_name:, action:,
                                                 actor:, export_id:,
                                                 content_hash:, privacy:,
                                                 status:, meaning_status:)
        view_matches = view_name.nil? || archive.view_name == token(view_name)
        action_matches = action.nil? || archive.action == token(action)
        actor_matches = actor.nil? || archive.actor == actor
        export_matches = export_id.nil? || archive.export_id == export_id
        hash_matches = content_hash.nil? || archive.content_hash == content_hash
        privacy_matches = privacy.nil? || archive.privacy == token(privacy)
        status_matches = status.nil? || archive.status == token(status)
        meaning_matches = meaning_status.nil? ||
                          archive.meaning_status == token(meaning_status)

        view_matches && action_matches && actor_matches && export_matches &&
          hash_matches && privacy_matches && status_matches && meaning_matches
      end

      def normalize_command_flow_view_horizon(horizon)
        data = normalize_value(horizon || {})
        mode = token(data[:mode])
        mode ||= inferred_command_flow_view_horizon_mode(data)
        unless %i[live reproducible].include?(mode)
          raise ArgumentError, "Unknown command_flow_view horizon mode: #{mode.inspect}"
        end

        data.merge(mode: mode)
      end

      def inferred_command_flow_view_horizon_mode(horizon)
        return :live if horizon.empty? || horizon[:as_of].nil? || horizon[:as_of] == :latest
        return :live if horizon[:rule_version].nil? || horizon[:rule_version] == :latest
        return :live if horizon[:fact_scope].nil?

        :reproducible
      end

      def command_flow_view_as_of(horizon)
        horizon[:as_of] == :latest ? nil : horizon[:as_of]
      end

      def ensure_command_flow_request_id(metadata)
        data = normalize_value(metadata || {})
        data[:request_id] ? data : data.merge(request_id: command_flow_request_id)
      end

      def command_flow_request_id
        "cmd_#{SecureRandom.hex(6)}"
      end

      def command_flow_lifecycle(activity_event, audit:, history_class:,
                                 apply_receipt: nil, policy_decision: nil)
        if audit
          return command_lifecycle(
            owner: activity_event.owner,
            command: activity_event.command,
            subject_key: activity_event.subject_key,
            request_id: activity_event.metadata[:request_id],
            history_class: history_class
          )
        end

        events = [command_flow_lifecycle_event(activity_event,
          apply_receipt: apply_receipt,
          policy_decision: policy_decision)]
        build_command_lifecycle(events,
          owner: activity_event.owner,
          command: activity_event.command,
          subject_key: activity_event.subject_key,
          request_id: activity_event.metadata[:request_id])
      end

      def command_flow_activity_event(plan, policy_decision)
        status = if !plan.ready? || !policy_decision.allowed?
          :rejected
        end

        command_activity_event(plan,
          status: status,
          metadata: command_flow_activity_metadata(policy_decision))
      end

      def command_flow_activity_metadata(policy_decision)
        {
          actor: policy_decision.actor,
          policy_status: policy_decision.status,
          lifecycle_stage: :preview
        }.compact
      end

      def command_flow_lifecycle_event(activity_event, apply_receipt:,
                                       policy_decision:)
        return activity_event unless apply_receipt

        CommandActivityEvent.new(
          owner: activity_event.owner,
          command: activity_event.command,
          subject_key: activity_event.subject_key,
          operation: activity_event.operation,
          status: apply_receipt.status,
          intent_status: activity_event.intent_status,
          plan_status: activity_event.plan_status,
          target: activity_event.target,
          errors: apply_receipt.errors,
          warnings: apply_receipt.warnings,
          metadata: command_flow_apply_metadata(activity_event, policy_decision)
        )
      end

      def command_flow_apply_metadata(activity_event, policy_decision)
        metadata = activity_event.metadata.merge(lifecycle_stage: :apply)
        return metadata unless policy_decision

        metadata.merge(
          actor: policy_decision.actor,
          policy_status: policy_decision.status
        ).compact
      end

      def build_command_flow(mode:, intent:, plan:, activity_event:,
                             policy_decision:, apply_receipt:, lifecycle:,
                             metadata:, actor:)
        CommandFlow.new(
          status: command_flow_status(mode, plan, policy_decision, apply_receipt),
          mode: mode,
          owner: intent.owner,
          command: intent.command,
          subject_key: intent.subject_key,
          request_id: metadata[:request_id],
          actor: actor,
          intent: intent,
          plan: plan,
          activity_event: activity_event,
          policy_decision: policy_decision,
          apply_receipt: apply_receipt,
          lifecycle: lifecycle,
          errors: command_flow_errors(plan, policy_decision, apply_receipt),
          warnings: command_flow_warnings(plan, policy_decision, apply_receipt),
          metadata: metadata
        )
      end

      def command_flow_status(mode, plan, policy_decision, apply_receipt)
        return apply_receipt.status if apply_receipt&.status == :applied
        return :rejected unless plan.ready?
        return :review_required if policy_decision&.review_required?
        return :policy_denied if policy_decision&.denied?
        return apply_receipt.status if mode == :apply && apply_receipt

        :planned
      end

      def command_flow_errors(plan, policy_decision, apply_receipt)
        source = apply_receipt || policy_decision || plan
        Array(source.errors)
      end

      def command_flow_warnings(plan, policy_decision, apply_receipt)
        source = apply_receipt || policy_decision || plan
        Array(source.warnings)
      end

      def policy_for_plan(plan)
        schema_class = @schema_by_store[token(plan.owner)]
        return {} unless schema_class&.respond_to?(:_commands)

        attrs = descriptor_entry(schema_class._commands, plan.command)
        normalized_command_policy(attrs || {}) || {}
      end

      def merge_policy(base_policy, explicit_policy)
        base = base_policy || {}
        explicit = normalized_command_policy(explicit_policy || {}) || {}
        requires = (Array(base[:requires]) + Array(explicit[:requires]))
          .map { |value| token(value) }
          .uniq
        review = if explicit.key?(:review)
          explicit[:review]
        else
          base[:review]
        end

        { requires: requires, review: !!review }
      end

      def normalized_command_policy(attrs)
        data = attrs.to_h.transform_keys(&:to_sym)
        nested = data[:policy].is_a?(Hash) ? data[:policy].transform_keys(&:to_sym) : {}
        has_requires = nested.key?(:requires) || data.key?(:requires)
        has_review = nested.key?(:review) || data.key?(:review)
        return nil unless has_requires || has_review

        requires = nested.key?(:requires) ? nested[:requires] : data[:requires]
        review = nested.key?(:review) ? nested[:review] : data[:review]
        {
          requires: Array(requires).map { |value| token(value) }.uniq,
          review: !!review
        }
      end

      def approval_matches?(plan, approvals)
        Array(approvals).any? do |raw|
          approval = normalize_value(raw)
          next false unless approval.is_a?(Hash)

          owner_matches = !approval.key?(:owner) || token(approval[:owner]) == plan.owner
          owner_matches &&
            token(approval[:command]) == plan.command &&
            approval[:subject_key] == plan.subject_key
        end
      end

      def policy_decision_errors(decision)
        return decision.errors if decision.errors.any?

        if decision.review_required?
          [plan_error(:review_required, "Command policy review is required")]
        else
          [plan_error(:policy_denied, "Command policy denied apply")]
        end
      end

      def build_command_lifecycle(events, owner:, command:, subject_key:, request_id:)
        latest = events.last
        return unknown_command_lifecycle(owner, command, subject_key, request_id) unless latest

        errors = events.flat_map { |event| Array(event.errors) }.uniq
        warnings = events.flat_map { |event| Array(event.warnings) }.uniq
        activity_statuses = events.map(&:status)
        lifecycle_status = command_lifecycle_status(latest)
        metadata = latest.metadata

        CommandLifecycle.new(
          status: lifecycle_status,
          owner: latest.owner,
          command: latest.command,
          subject_key: latest.subject_key,
          request_id: request_id || metadata[:request_id],
          actor: metadata[:actor],
          operation: latest.operation,
          target: latest.target,
          intent_status: latest.intent_status,
          plan_status: latest.plan_status,
          policy_status: lifecycle_policy_status(latest),
          apply_status: lifecycle_apply_status(latest),
          activity_statuses: activity_statuses,
          errors: errors,
          warnings: warnings,
          metadata: metadata,
          latest_activity: latest.to_h,
          store_fact_exposed: false,
          value_hash_exposed: false
        )
      end

      def unknown_command_lifecycle(owner, command, subject_key, request_id)
        CommandLifecycle.new(
          status: :unknown,
          owner: owner,
          command: command,
          subject_key: subject_key,
          request_id: request_id,
          activity_statuses: [],
          errors: [],
          warnings: [],
          metadata: {},
          latest_activity: nil
        )
      end

      def command_lifecycle_status(activity)
        return :applied if activity.status == :applied
        return :review_required if activity.status == :rejected && review_error?(activity)
        return :policy_denied if activity.status == :rejected && policy_error?(activity)
        return :rejected if activity.status == :rejected
        return :planned if activity.status == :planned
        return :intended if activity.status == :intended

        token(activity.status) || :unknown
      end

      def lifecycle_policy_status(activity)
        return activity.metadata[:policy_status] if activity.metadata[:policy_status]
        return :review_required if review_error?(activity)
        return :denied if policy_error?(activity)

        nil
      end

      def lifecycle_apply_status(activity)
        return nil unless activity.metadata[:lifecycle_stage] == :apply

        activity.status
      end

      def review_error?(activity)
        activity_errors(activity).any? { |error| error[:code] == :review_required }
      end

      def policy_error?(activity)
        activity_errors(activity).any? do |error|
          %i[missing_capabilities policy_denied].include?(error[:code])
        end
      end

      def activity_errors(activity)
        Array(activity.errors).select { |error| error.is_a?(Hash) }
      end

      def apply_activity_metadata(plan, policy_decision)
        metadata = plan.metadata.merge(lifecycle_stage: :apply)
        return metadata unless policy_decision

        metadata.merge(
          actor: policy_decision.actor,
          policy_status: policy_decision.status
        ).compact
      end

      def apply_record_update_command(plan, audit:, activity_history_class:,
                                      policy_decision:)
        schema_class = registered_record_schema_for(plan.owner)
        unless schema_class
          return rejected_command_apply_receipt(plan,
            errors: [plan_error(:schema_not_registered,
              "No Record schema registered for owner=#{plan.owner.inspect}")],
            audit: audit,
            activity_history_class: activity_history_class)
        end

        unless plan.subject_key
          return rejected_command_apply_receipt(plan,
            errors: [plan_error(:missing_key,
              "record_update command apply requires subject_key")],
            audit: audit,
            activity_history_class: activity_history_class)
        end

        write(schema_class, key: plan.subject_key, **apply_value(plan))
        applied_command_receipt(plan,
          target: command_target_with_key(plan, plan.subject_key),
          mutation_intent: :record_write,
          activity_recorded: record_apply_activity(plan,
            status: :applied,
            audit: audit,
            activity_history_class: activity_history_class,
            policy_decision: policy_decision))
      end

      def apply_record_append_command(plan, key:, audit:, activity_history_class:,
                                      policy_decision:)
        schema_class = registered_record_schema_for(plan.owner)
        unless schema_class
          return rejected_command_apply_receipt(plan,
            errors: [plan_error(:schema_not_registered,
              "No Record schema registered for owner=#{plan.owner.inspect}")],
            audit: audit,
            activity_history_class: activity_history_class)
        end

        applied_key = key || plan.subject_key
        unless applied_key
          return rejected_command_apply_receipt(plan,
            errors: [plan_error(:missing_key,
              "record_append command apply requires explicit key")],
            audit: audit,
            activity_history_class: activity_history_class)
        end

        write(schema_class, key: applied_key, **apply_value(plan))
        applied_command_receipt(plan,
          target: command_target_with_key(plan, applied_key),
          mutation_intent: :record_write,
          activity_recorded: record_apply_activity(plan,
            status: :applied,
            audit: audit,
            activity_history_class: activity_history_class,
            policy_decision: policy_decision))
      end

      def apply_history_append_command(plan, history_class:, audit:,
                                       activity_history_class:,
                                       policy_decision:)
        target_name = plan.target.is_a?(Hash) ? plan.target[:name] : nil
        resolved_history_class = history_class || registered_history_schema_for(target_name)
        unless resolved_history_class
          return rejected_command_apply_receipt(plan,
            errors: [plan_error(:history_not_registered,
              "No History schema registered for target=#{target_name.inspect}")],
            audit: audit,
            activity_history_class: activity_history_class)
        end

        register(resolved_history_class) if history_class
        append(resolved_history_class, **apply_event(plan))
        applied_command_receipt(plan,
          target: plan.target,
          mutation_intent: :history_append,
          activity_recorded: record_apply_activity(plan,
            status: :applied,
            audit: audit,
            activity_history_class: activity_history_class,
            policy_decision: policy_decision))
      end

      def registered_record_schema_for(store_name)
        schema_class = @schema_by_store[token(store_name)]
        return nil if schema_class&.respond_to?(:_partition_key)

        schema_class
      end

      def registered_history_schema_for(store_name)
        schema_class = @schema_by_store[token(store_name)]
        return schema_class if schema_class&.respond_to?(:_partition_key)

        nil
      end

      def apply_value(plan)
        plan.value.is_a?(Hash) ? plan.value : {}
      end

      def apply_event(plan)
        plan.event.is_a?(Hash) ? plan.event : {}
      end

      def command_target_with_key(plan, key)
        target = plan.target.is_a?(Hash) ? plan.target : {}
        target.merge(key: key)
      end

      def applied_command_receipt(plan, target:, mutation_intent:,
                                  activity_recorded:)
        CommandApplyReceipt.new(
          status: :applied,
          owner: plan.owner,
          command: plan.command,
          subject_key: plan.subject_key,
          operation: plan.operation,
          target: target,
          mutation_intent: mutation_intent,
          activity_recorded: activity_recorded,
          errors: [],
          warnings: plan.warnings
        )
      end

      def rejected_command_apply_receipt(plan, errors: [], warnings: [],
                                         policy_decision: nil, audit:,
                                         activity_history_class:)
        all_errors = (Array(plan.errors) + Array(errors)).uniq
        all_warnings = (Array(plan.warnings) + Array(warnings)).uniq
        activity_recorded = record_apply_activity(plan,
          status: :rejected,
          errors: all_errors,
          warnings: all_warnings,
          audit: audit,
          activity_history_class: activity_history_class,
          policy_decision: policy_decision)
        CommandApplyReceipt.new(
          status: :rejected,
          owner: plan.owner,
          command: plan.command,
          subject_key: plan.subject_key,
          operation: plan.operation,
          target: plan.target,
          mutation_intent: :none,
          activity_recorded: activity_recorded,
          errors: all_errors,
          warnings: all_warnings
        )
      end

      def record_apply_activity(plan, status:, audit:, activity_history_class:,
                                errors: plan.errors, warnings: plan.warnings,
                                policy_decision: nil)
        return false unless audit

        event = CommandActivityEvent.new(
          owner: plan.owner,
          command: plan.command,
          subject_key: plan.subject_key,
          operation: plan.operation,
          status: status,
          intent_status: :ready,
          plan_status: plan.status,
          target: plan.target,
          errors: errors,
          warnings: warnings,
          metadata: apply_activity_metadata(plan, policy_decision)
        )
        append_command_activity(event, history_class: activity_history_class)
        true
      end
    end
  end
end
