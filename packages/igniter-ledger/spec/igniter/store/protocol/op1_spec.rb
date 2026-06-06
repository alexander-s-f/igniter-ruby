# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe "OP1 — Descriptor Packet Import" do
  subject(:proto) { Igniter::Store::Protocol.new }

  # ------------------------------------------------------------------ Receipt contract

  describe "Receipt value object" do
    it "accepted? is true for :accepted status" do
      r = Igniter::Store::Protocol::Receipt.accepted(kind: :store, name: :tasks)
      expect(r.accepted?).to be true
      expect(r.rejected?).to be false
    end

    it "rejected? is true for :rejected status" do
      r = Igniter::Store::Protocol::Receipt.rejection("oops", kind: :store)
      expect(r.rejected?).to be true
      expect(r.errors).to include("oops")
    end

    it "deduplicated? is true for :deduplicated status" do
      r = Igniter::Store::Protocol::Receipt.deduplicated(kind: :store, name: :tasks)
      expect(r.deduplicated?).to be true
    end

    it "write_accepted carries fact_id and value_hash" do
      store = Igniter::Store::IgniterStore.new
      fact  = store.write(store: :x, key: "k", value: { n: 1 })
      r = Igniter::Store::Protocol::Receipt.write_accepted(store: :x, key: "k", fact: fact)
      expect(r.fact_id).to   eq(fact.id)
      expect(r.value_hash).to eq(fact.value_hash)
      expect(r.accepted?).to  be true
    end

    it "append_accepted carries generated key, fact_id, and value_hash" do
      store = Igniter::Store::IgniterStore.new
      fact = store.append(history: :events, event: { event_id: "evt_1" })
      r = Igniter::Store::Protocol::Receipt.append_accepted(history: :events, fact: fact, requested_key: "client-key")

      expect(r.kind).to       eq(:append_receipt)
      expect(r.store).to      eq(:events)
      expect(r.key).to        eq(fact.key)
      expect(r.fact_id).to    eq(fact.id)
      expect(r.value_hash).to eq(fact.value_hash)
      expect(r.warnings.first).to match(/metadata only/)
    end
  end

  # ------------------------------------------------------------------ Fact#producer

  describe "Fact#producer" do
    it "is nil when not specified" do
      store = Igniter::Store::IgniterStore.new
      fact  = store.write(store: :x, key: "k", value: { n: 1 })
      expect(fact.producer).to be_nil
    end

    context "producer: storage" do
      it "stores the producer hash when provided" do
        store = Igniter::Store::IgniterStore.new
        p = { system: :demo_dsl, name: :TaskFlow }
        fact = store.write(store: :x, key: "k", value: { n: 1 }, producer: p)
        expect(fact.producer[:system]).to eq(:demo_dsl)
        expect(fact.producer[:name]).to   eq(:TaskFlow)
      end

      it "freezes the producer value" do
        store = Igniter::Store::IgniterStore.new
        fact  = store.write(store: :x, key: "k", value: { n: 1 }, producer: { system: :test })
        expect(fact.producer).to be_frozen
      end
    end
  end

  # ------------------------------------------------------------------ Protocol.new factory

  describe "Protocol.new factory" do
    it "returns a Protocol::Interpreter" do
      expect(proto).to be_a(Igniter::Store::Protocol::Interpreter)
    end

    it "accepts an existing store" do
      inner = Igniter::Store::IgniterStore.new
      p = Igniter::Store::Protocol.new(inner)
      expect(p).to be_a(Igniter::Store::Protocol::Interpreter)
    end
  end

  # ------------------------------------------------------------------ IgniterStore#protocol accessor

  describe "IgniterStore#protocol" do
    let(:store) { Igniter::Store::IgniterStore.new }

    it "returns a Protocol::Interpreter" do
      expect(store.protocol).to be_a(Igniter::Store::Protocol::Interpreter)
    end

    it "is memoized" do
      expect(store.protocol).to be(store.protocol)
    end

    it "register_descriptor delegates to protocol.register" do
      receipt = store.register_descriptor(
        schema_version: 1, kind: :store, name: :widgets, key: :id, fields: []
      )
      expect(receipt.accepted?).to be true
      expect(receipt.kind).to eq(:store)
    end
  end

  # ------------------------------------------------------------------ append

  describe "append" do
    it "appends a history event and returns an append receipt" do
      store = Igniter::Store::IgniterStore.new
      proto = Igniter::Store::Protocol.new(store)

      receipt = proto.append(
        history: :contractable_events,
        event: { event_id: "evt_1", observation_id: "obs_1" },
        partition_key: :observation_id,
        producer: { system: :spec }
      )

      expect(receipt.accepted?).to be true
      expect(receipt.kind).to eq(:append_receipt)
      expect(receipt.store).to eq(:contractable_events)
      expect(receipt.key).not_to be_nil
      expect(receipt.fact_id).not_to be_nil
      expect(receipt.value_hash).not_to be_nil

      events = store.history_partition(
        store: :contractable_events,
        partition_key: :observation_id,
        partition_value: "obs_1"
      )
      expect(events.length).to eq(1)
      expect(events.first.value).to include(event_id: "evt_1")
      expect(events.first.producer).to eq(system: :spec)
    end
  end

  # ------------------------------------------------------------------ kind: dispatch

  describe "kind: dispatch" do
    it "rejects a missing kind field" do
      r = proto.register({ schema_version: 1, name: :x })
      expect(r.rejected?).to be true
      expect(r.errors.first).to match(/kind/)
    end

    it "rejects an unknown kind" do
      r = proto.register({ kind: :wormhole, name: :x })
      expect(r.rejected?).to be true
      expect(r.errors.first).to match(/wormhole/)
    end
  end

  # ------------------------------------------------------------------ store descriptor

  describe "register_store" do
    it "accepts a valid store descriptor" do
      r = proto.register_store(
        schema_version: 1, kind: :store,
        name: :tasks, key: :id,
        fields: [{ name: :id, type: :string, required: true }, { name: :status, type: :symbol }],
        producer: { system: :demo_dsl, name: :Task }
      )
      expect(r.accepted?).to be true
      expect(r.name).to eq(:tasks)
    end

    it "rejects a descriptor missing name" do
      r = proto.register_store(schema_version: 1, kind: :store, key: :id, fields: [])
      expect(r.rejected?).to be true
    end

    it "rejects a descriptor missing key" do
      r = proto.register_store(schema_version: 1, kind: :store, name: :tasks, fields: [])
      expect(r.rejected?).to be true
    end

    it "stores the descriptor in schema_graph for OP2 introspection" do
      proto.register_store(schema_version: 1, kind: :store, name: :orders, key: :id, fields: [])
      snap = proto.descriptor_snapshot
      expect(snap[:stores][:orders]).to include(name: :orders)
    end
  end

  # ------------------------------------------------------------------ history descriptor

  describe "register_history" do
    it "accepts a valid history descriptor" do
      r = proto.register_history(
        schema_version: 1, kind: :history,
        name: :task_events, key: :task_id,
        event_field: :event, timestamp_field: :at
      )
      expect(r.accepted?).to be true
      expect(r.name).to eq(:task_events)
    end

    it "stores the descriptor in schema_graph" do
      proto.register_history(schema_version: 1, kind: :history, name: :order_events, key: :order_id)
      snap = proto.descriptor_snapshot
      expect(snap[:histories][:order_events]).to include(name: :order_events)
    end
  end

  # ------------------------------------------------------------------ access_path descriptor

  describe "register_access_path" do
    before do
      proto.register_store(schema_version: 1, kind: :store, name: :tasks, key: :id, fields: [])
    end

    it "accepts a valid access_path descriptor" do
      r = proto.register_access_path(
        schema_version: 1, kind: :access_path,
        name: :tasks_by_status, store: :tasks, fields: [:status], unique: false
      )
      expect(r.accepted?).to be true
      expect(r.name).to eq(:tasks_by_status)
    end

    it "rejects when store field is missing" do
      r = proto.register_access_path(
        schema_version: 1, kind: :access_path,
        name: :tasks_by_status, fields: [:status]
      )
      expect(r.rejected?).to be true
    end

    it "includes a warning for non-unique access paths" do
      r = proto.register_access_path(
        schema_version: 1, kind: :access_path,
        name: :tasks_by_status, store: :tasks, fields: [:status], unique: false
      )
      expect(r.warnings).not_to be_empty
    end
  end

  # ------------------------------------------------------------------ relation descriptor

  describe "register_relation" do
    it "accepts a valid relation descriptor" do
      r = proto.register_relation(
        schema_version: 1, kind: :relation,
        name: :project_tasks,
        from: { store: :projects, key: :id },
        to:   { store: :tasks, field: :project_id },
        cardinality: :many
      )
      expect(r.accepted?).to be true
      expect(r.name).to eq(:project_tasks)
    end

    it "rejects when from: is malformed" do
      r = proto.register_relation(
        schema_version: 1, kind: :relation,
        name: :project_tasks,
        from: { store: :projects },   # missing key:
        to:   { store: :tasks, field: :project_id },
        cardinality: :many
      )
      expect(r.rejected?).to be true
    end

    it "rejects when to: is malformed" do
      r = proto.register_relation(
        schema_version: 1, kind: :relation,
        name: :project_tasks,
        from: { store: :projects, key: :id },
        to:   { store: :tasks },   # missing field:
        cardinality: :many
      )
      expect(r.rejected?).to be true
    end

    it "includes a warning for cardinality: :one" do
      r = proto.register_relation(
        schema_version: 1, kind: :relation,
        name: :user_profile,
        from: { store: :users, key: :id },
        to:   { store: :profiles, field: :user_id },
        cardinality: :one
      )
      expect(r.warnings).not_to be_empty
    end
  end

  # ------------------------------------------------------------------ projection descriptor

  describe "register_projection" do
    it "accepts a valid projection descriptor" do
      r = proto.register_projection(
        schema_version: 1, kind: :projection,
        name: :open_task_counts,
        source: :tasks,
        group_by: [:project_id],
        compute: { count_where: { status: :open } }
      )
      expect(r.accepted?).to be true
      expect(r.name).to eq(:open_task_counts)
    end

    it "accepts Durable Model projection descriptors with reads and relations" do
      r = proto.register_projection(
        schema_version: 1,
        kind: :projection,
        name: :tracker_dashboard,
        reads: [:trackers, :tracker_logs],
        relations: [:logs_by_tracker],
        consumer_hint: :contract_node,
        reactive: true
      )

      snapshot = proto.metadata_snapshot[:projections]
      expect(r.accepted?).to be true
      expect(snapshot[:tracker_dashboard]).to include(
        reads: [:trackers, :tracker_logs],
        relations: [:logs_by_tracker],
        consumer_hint: :contract_node,
        reactive: true,
        store_count: 2,
        relation_count: 1
      )
    end

    it "keeps mode: :materialized as the reactive default" do
      proto.register_projection(
        schema_version: 1, kind: :projection,
        name: :materialized_counts,
        source: :tasks,
        mode: :materialized
      )

      expect(proto.metadata_snapshot[:projections][:materialized_counts][:reactive]).to be true
    end

    it "lets explicit reactive override mode" do
      proto.register_projection(
        schema_version: 1, kind: :projection,
        name: :manual_projection,
        source: :tasks,
        mode: :materialized,
        reactive: false
      )

      expect(proto.metadata_snapshot[:projections][:manual_projection][:reactive]).to be false
    end

    it "rejects projection descriptors with no reads or source" do
      r = proto.register_projection(schema_version: 1, kind: :projection, name: :empty_projection)
      expect(r.rejected?).to be true
    end
  end

  # ------------------------------------------------------------------ derivation descriptor (metadata only)

  describe "register_derivation" do
    it "accepts with a metadata-only warning" do
      r = proto.register_derivation(
        schema_version: 1, kind: :derivation,
        name: :today_focus,
        inputs: [:tasks, :calendar_events],
        output: :focus_items,
        mode: :materialized
      )
      expect(r.accepted?).to be true
      expect(r.warnings).not_to be_empty
      expect(r.warnings.first).to match(/metadata only/)
    end
  end

  # ------------------------------------------------------------------ command/effect descriptors (metadata only)

  describe "register_command" do
    it "accepts a valid command descriptor and exposes it in metadata" do
      r = proto.register_command(
        schema_version: 1,
        kind: :command,
        name: :complete,
        owner: :reminders,
        operation: :record_update,
        changes: { status: :done }
      )

      command = proto.metadata_snapshot[:commands][:reminders][:complete]

      expect(r.accepted?).to be true
      expect(command).to include(
        name: :complete,
        owner: :reminders,
        operation: :record_update,
        target_shape: :store,
        boundary: :app,
        mutation_intent: :record_update,
        changes: { status: :done }
      )
    end

    it "rejects missing command fields clearly" do
      r = proto.register_command(schema_version: 1, kind: :command, name: :complete)

      expect(r.rejected?).to be true
      expect(r.errors.first).to match(/owner, operation/)
    end

    it "rejects unsupported command operations" do
      r = proto.register_command(
        schema_version: 1,
        kind: :command,
        name: :complete,
        owner: :reminders,
        operation: :teleport
      )

      expect(r.rejected?).to be true
      expect(r.errors.first).to match(/Unsupported command operation/)
    end
  end

  describe "register_effect" do
    it "accepts a valid effect descriptor and exposes it in metadata" do
      r = proto.register_effect(
        schema_version: 1,
        kind: :effect,
        name: :complete,
        owner: :reminders,
        store_op: :store_write,
        write_kind: :update,
        source_operation: :record_update
      )

      effect = proto.metadata_snapshot[:effects][:reminders][:complete]

      expect(r.accepted?).to be true
      expect(effect).to include(
        name: :complete,
        owner: :reminders,
        store_op: :store_write,
        write_kind: :update,
        lowers_to: :store_t,
        boundary: :app,
        source_operation: :record_update
      )
    end

    it "rejects invalid effect descriptors clearly" do
      r = proto.register_effect(
        schema_version: 1,
        kind: :effect,
        name: :complete,
        owner: :reminders,
        store_op: :system_shell,
        write_kind: :update
      )

      expect(r.rejected?).to be true
      expect(r.errors.first).to match(/Unsupported effect store_op/)
    end

    it "includes command and effect descriptors in descriptor_snapshot" do
      proto.register_command(
        schema_version: 1,
        kind: :command,
        name: :complete,
        owner: :reminders,
        operation: :record_update
      )
      proto.register_effect(
        schema_version: 1,
        kind: :effect,
        name: :complete,
        owner: :reminders,
        store_op: :store_write,
        write_kind: :update
      )

      snap = proto.descriptor_snapshot

      expect(snap[:commands][:reminders]).to have_key(:complete)
      expect(snap[:effects][:reminders]).to have_key(:complete)
    end
  end

  # ------------------------------------------------------------------ subscription descriptor

  describe "register_subscription" do
    it "accepts a valid subscription descriptor" do
      r = proto.register_subscription(
        schema_version: 1, kind: :subscription,
        name: :open_tasks_changed,
        source: :tasks,
        where: { status: :open },
        events: [:write, :delete, :compact]
      )
      expect(r.accepted?).to be true
      expect(r.name).to eq(:open_tasks_changed)
    end

    it "stores the descriptor in schema_graph" do
      proto.register_subscription(
        schema_version: 1, kind: :subscription,
        name: :any_task_changed, source: :tasks
      )
      snap = proto.descriptor_snapshot
      expect(snap[:subscriptions][:any_task_changed]).to include(name: :any_task_changed)
    end
  end

  # ------------------------------------------------------------------ content-addressed deduplication

  describe "deduplication" do
    it "returns :deduplicated for an identical descriptor registered twice" do
      descriptor = { schema_version: 1, kind: :store, name: :things, key: :id, fields: [] }
      first  = proto.register(descriptor)
      second = proto.register(descriptor)

      expect(first.accepted?).to     be true
      expect(second.deduplicated?).to be true
    end

    it "accepts a different descriptor even for the same name" do
      proto.register({ schema_version: 1, kind: :store, name: :things, key: :id, fields: [] })
      r = proto.register({ schema_version: 1, kind: :store, name: :things, key: :uuid, fields: [] })
      expect(r.accepted?).to be true
    end
  end

  # ------------------------------------------------------------------ Non-Igniter client example (OP1 success signal)

  describe "Non-Igniter client example" do
    it "registers a store and access_path, writes and queries facts without Igniter::Contract" do
      proto.register_store(
        schema_version: 1, kind: :store,
        name: :tasks, key: :id,
        fields: [
          { name: :id,     type: :string, required: true },
          { name: :status, type: :symbol }
        ],
        producer: { system: :demo_dsl, name: :Task }
      )

      proto.register_access_path(
        schema_version: 1, kind: :access_path,
        name: :tasks_by_status, store: :tasks, fields: [:status]
      )

      receipt = proto.write(
        store: :tasks,
        key: "t1",
        value: { id: "t1", status: :pending },
        producer: { system: :demo_dsl, name: :TaskFlow }
      )

      proto.write(store: :tasks, key: "t2", value: { id: "t2", status: :open })
      proto.write(store: :tasks, key: "t3", value: { id: "t3", status: :pending })

      expect(receipt.accepted?).to      be true
      expect(receipt.fact_id).not_to    be_nil
      expect(receipt.value_hash).not_to be_nil

      pending_tasks = proto.query(store: :tasks, where: { status: :pending })
      expect(pending_tasks.size).to eq(2)
      expect(pending_tasks.map { |t| t[:key] }).to contain_exactly("t1", "t3")
      expect(pending_tasks.map { |t| t[:value][:id] }).to contain_exactly("t1", "t3")

      open_tasks = proto.query(store: :tasks, where: { status: :open })
      expect(open_tasks.size).to eq(1)
      expect(open_tasks.first[:key]).to eq("t2")
      expect(open_tasks.first[:value][:id]).to eq("t2")

      all_tasks = proto.query(store: :tasks)
      expect(all_tasks.size).to eq(3)
    end
  end

  # ------------------------------------------------------------------ relation via protocol

  describe "relation via protocol — project_tasks" do
    it "registers a relation and resolves it after writing source facts" do
      proto.register_relation(
        schema_version: 1, kind: :relation,
        name: :project_tasks,
        from: { store: :projects, key: :id },
        to:   { store: :tasks, field: :project_id },
        cardinality: :many
      )

      proto.write(store: :tasks, key: "t1", value: { title: "Alpha", project_id: "p1" })
      proto.write(store: :tasks, key: "t2", value: { title: "Beta",  project_id: "p1" })
      proto.write(store: :tasks, key: "t3", value: { title: "Gamma", project_id: "p2" })

      p1_tasks = proto.resolve(:project_tasks, from: "p1")
      p2_tasks = proto.resolve(:project_tasks, from: "p2")

      expect(p1_tasks.size).to eq(2)
      expect(p2_tasks.size).to eq(1)
      expect(p1_tasks.map { |t| t[:title] }).to contain_exactly("Alpha", "Beta")
    end
  end

  # ------------------------------------------------------------------ OP2: unified metadata_snapshot

  describe "OP2 — metadata_snapshot (unified)" do
    before do
      proto.register_store(
        schema_version: 1, kind: :store,
        name: :widgets, key: :id,
        fields: [{ name: :id, type: :string }, { name: :color, type: :symbol }]
      )
      proto.register_access_path(
        schema_version: 1, kind: :access_path,
        name: :widgets_by_color, store: :widgets, fields: [:color]
      )
      proto.register_history(
        schema_version: 1, kind: :history,
        name: :widget_events, key: :widget_id
      )
      proto.register_relation(
        schema_version: 1, kind: :relation,
        name: :warehouse_widgets,
        from: { store: :warehouses, key: :id },
        to:   { store: :widgets, field: :warehouse_id },
        cardinality: :many
      )
      proto.register_subscription(
        schema_version: 1, kind: :subscription,
        name: :widget_changed, source: :widgets
      )
    end

    it "has schema_version: 1" do
      expect(proto.metadata_snapshot[:schema_version]).to eq(1)
    end

    it "includes registered store descriptors under :stores" do
      snap = proto.metadata_snapshot
      expect(snap[:stores]).to have_key(:widgets)
      expect(snap[:stores][:widgets]).to include(name: :widgets, key: :id)
    end

    it "includes registered history descriptors under :histories" do
      snap = proto.metadata_snapshot
      expect(snap[:histories]).to have_key(:widget_events)
    end

    it "includes access path routing metadata under :access_paths" do
      snap = proto.metadata_snapshot
      expect(snap[:access_paths][:widgets]).to be_an(Array)
      expect(snap[:access_paths][:widgets].map { |p| p[:scope] }).to include(:widgets_by_color)
    end

    it "includes relation rules under :relations" do
      snap = proto.metadata_snapshot
      expect(snap[:relations]).to have_key(:warehouse_widgets)
      expect(snap[:relations][:warehouse_widgets]).to include(
        source: :widgets, partition: :warehouse_id
      )
    end

    it "includes subscription descriptors under :subscriptions" do
      snap = proto.metadata_snapshot
      expect(snap[:subscriptions]).to have_key(:widget_changed)
    end

    it "includes :derivations, :scatters, :projections, :commands, :effects, :retention keys" do
      snap = proto.metadata_snapshot
      expect(snap).to have_key(:derivations)
      expect(snap).to have_key(:scatters)
      expect(snap).to have_key(:projections)
      expect(snap).to have_key(:commands)
      expect(snap).to have_key(:effects)
      expect(snap).to have_key(:retention)
    end

    it "includes scatter rules auto-created by register_relation" do
      snap = proto.metadata_snapshot
      expect(snap[:scatters].any? { |s| s[:source_store] == :widgets }).to be true
    end
  end

  # ------------------------------------------------------------------ descriptor_snapshot (low-level)

  describe "descriptor_snapshot (low-level)" do
    it "includes registered store and subscription descriptors" do
      proto.register_store(schema_version: 1, kind: :store, name: :alerts, key: :id, fields: [])
      proto.register_subscription(
        schema_version: 1, kind: :subscription, name: :alert_fired, source: :alerts
      )
      snap = proto.descriptor_snapshot
      expect(snap[:stores]).to        have_key(:alerts)
      expect(snap[:subscriptions]).to have_key(:alert_fired)
    end
  end

  # ------------------------------------------------------------------ write_fact(packet)

  describe "write_fact(packet)" do
    it "accepts a valid fact packet and returns a write Receipt" do
      r = proto.write_fact(
        schema_version: 1,
        kind:  :fact,
        store: :tasks,
        key:   "t1",
        value: { id: "t1", status: :open },
        valid_time: 1_714_200_123.5,
        producer: { system: :external_client, name: :demo },
        derivation: { name: :seed_task, source_fact_ids: ["source-1"] }
      )
      expect(r.accepted?).to  be true
      expect(r.fact_id).not_to be_nil
      expect(r.store).to      eq(:tasks)
      expect(r.key).to        eq("t1")
    end

    it "stores canonical fact metadata from packet ingress" do
      proto.write_fact(
        schema_version: 1,
        kind: :fact,
        store: :tasks,
        key: "t1",
        value: { id: "t1", status: :open },
        valid_time: 1_714_200_123.5,
        producer: { system: :external_client, name: :demo },
        derivation: { name: :seed_task, source_fact_ids: ["source-1"] }
      )

      fact = proto.instance_variable_get(:@store).history(store: :tasks, key: "t1").last
      expect(fact.valid_time).to eq(1_714_200_123.5)
      expect(fact.producer[:system]).to eq(:external_client)
      expect(fact.derivation[:name]).to eq(:seed_task)
      expect(fact.derivation[:source_fact_ids]).to eq(["source-1"])
    end

    it "the written fact is readable via read" do
      proto.write_fact(kind: :fact, store: :tasks, key: "t1", value: { status: :open })
      val = proto.read(store: :tasks, key: "t1")
      expect(val[:status]).to eq(:open)
    end

    it "rejects a packet with wrong kind" do
      r = proto.write_fact(kind: :store, store: :tasks, key: "t1", value: {})
      expect(r.rejected?).to be true
      expect(r.errors.first).to match(/kind/)
    end

    it "rejects a packet missing store:" do
      r = proto.write_fact(kind: :fact, key: "t1", value: {})
      expect(r.rejected?).to be true
    end

    it "rejects a packet missing value:" do
      r = proto.write_fact(kind: :fact, store: :tasks, key: "t1")
      expect(r.rejected?).to be true
    end

    it "successive write_fact calls build a causation chain" do
      proto.write_fact(kind: :fact, store: :tasks, key: "t1", value: { status: :open })
      proto.write_fact(kind: :fact, store: :tasks, key: "t1", value: { status: :done })
      chain = proto.instance_variable_get(:@store).causation_chain(store: :tasks, key: "t1")
      expect(chain.size).to   eq(2)
      expect(chain[1][:causation]).to eq(chain[0][:id])
    end
  end
end
