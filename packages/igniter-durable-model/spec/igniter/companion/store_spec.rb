# frozen_string_literal: true

require_relative "../../spec_helper"

# ── Schema definitions used across the suite ──────────────────────────────────

class Reminder
  include Igniter::Companion::Record
  store_name :reminders

  field :title
  field :status, default: :open
  field :due,    default: nil

  scope :open, filters: { status: :open }
  scope :done, filters: { status: :done }
end

class TrackerLog
  include Igniter::Companion::History
  history_name :tracker_logs
  partition_key :tracker_id

  field :tracker_id
  field :value
  field :notes, default: nil
end

class CommandedReminder
  include Igniter::Companion::Record
  store_name :commanded_reminders

  field :id
  field :title
  field :status, default: :open

  command :complete,
    operation: :record_update,
    changes: { status: :done },
    policy: { requires: [:reminder_complete], review: false }

  command :review_complete,
    operation: :record_update,
    changes: { status: :done },
    requires: [:reminder_complete],
    review: true

  command :draft,
    operation: :record_append,
    changes: { status: :open }

  command :audit,
    operation: :history_append,
    event: { event: :audited }

  command :noop,
    operation: :none
end

class StringCommandReminder
  include Igniter::Companion::Record
  store_name :string_command_reminders

  field :title
  command "complete",
    "operation" => "record_update",
    "changes" => { "status" => "done" }
end

# ── Store specs ───────────────────────────────────────────────────────────────

RSpec.describe Igniter::Companion::Store do
  subject(:store) do
    s = described_class.new
    s.register(Reminder)
    s
  end

  # ── Record round-trip ──────────────────────────────────────────────────────

  describe "Record write / read round-trip" do
    it "returns a WriteReceipt that delegates to the typed record" do
      r = store.write(Reminder, key: "r1", title: "Buy milk", status: :open)

      expect(r).to be_a(Igniter::Companion::WriteReceipt)
      expect(r.mutation_intent).to eq(:record_write)
      expect(r.fact_id).not_to be_nil
      expect(r.value_hash).not_to be_nil
      expect(r.key).to eq("r1")
      expect(r.record).to be_a(Reminder)
      # delegation to record
      expect(r.title).to eq("Buy milk")
      expect(r.status).to eq(:open)
    end

    it "reads back the same value with Symbol-typed fields" do
      store.write(Reminder, key: "r1", title: "Buy milk", status: :open)
      r = store.read(Reminder, key: "r1")

      expect(r.title).to eq("Buy milk")
      expect(r.status).to eq(:open)    # Symbol survives JSON round-trip via igniter-ledger
    end

    it "applies field defaults on read when value has no entry for that field" do
      store.write(Reminder, key: "r1", title: "A", status: :open)
      r = store.read(Reminder, key: "r1")

      expect(r.due).to be_nil  # default from field declaration
    end

    it "returns nil for unknown keys" do
      expect(store.read(Reminder, key: "nonexistent")).to be_nil
    end

    it "reflects the latest write after an update" do
      store.write(Reminder, key: "r1", title: "Old",  status: :open)
      store.write(Reminder, key: "r1", title: "New",  status: :done)

      r = store.read(Reminder, key: "r1")
      expect(r.title).to eq("New")
      expect(r.status).to eq(:done)
    end

    it "exposes a causation chain across writes" do
      store.write(Reminder, key: "r1", title: "A", status: :open)
      store.write(Reminder, key: "r1", title: "A", status: :done)

      chain = store.causation_chain(Reminder, key: "r1")
      expect(chain.length).to eq(2)
      expect(chain.first[:causation]).to be_nil
      expect(chain.last[:causation]).not_to be_nil
    end
  end

  # ── Scope queries ──────────────────────────────────────────────────────────

  describe "Record scope queries" do
    before do
      store.write(Reminder, key: "r1", title: "A", status: :open)
      store.write(Reminder, key: "r2", title: "B", status: :done)
      store.write(Reminder, key: "r3", title: "C", status: :open)
    end

    it "returns only records matching the scope filter" do
      results = store.scope(Reminder, :open)
      expect(results.map(&:title).sort).to eq(%w[A C])
    end

    it "returns Record instances, not raw facts" do
      results = store.scope(Reminder, :open)
      expect(results).to all(be_a(Reminder))
    end

    it "reflects state after status change" do
      store.write(Reminder, key: "r1", title: "A", status: :done)

      open_results = store.scope(Reminder, :open)
      done_results = store.scope(Reminder, :done)

      expect(open_results.map(&:title)).to eq(["C"])
      expect(done_results.map(&:title).sort).to eq(%w[A B])
    end

    it "raises ArgumentError for an unregistered scope" do
      expect { store.scope(Reminder, :archived) }
        .to raise_error(ArgumentError, /scope=:archived/)
    end
  end

  # ── Time-travel reads ──────────────────────────────────────────────────────

  describe "time-travel" do
    it "reads the past state of a record via as_of" do
      store.write(Reminder, key: "r1", title: "A", status: :open)
      sleep 0.01
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.write(Reminder, key: "r1", title: "A", status: :done)

      past = store.read(Reminder, key: "r1", as_of: checkpoint)
      expect(past.status).to eq(:open)

      now = store.read(Reminder, key: "r1")
      expect(now.status).to eq(:done)
    end

    it "queries a scope at a past point in time" do
      store.write(Reminder, key: "r1", title: "A", status: :open)
      sleep 0.01
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.write(Reminder, key: "r1", title: "A", status: :done)

      at_checkpoint = store.scope(Reminder, :open, as_of: checkpoint)
      expect(at_checkpoint.map(&:title)).to eq(["A"])

      now = store.scope(Reminder, :open)
      expect(now).to be_empty
    end
  end

  # ── Reactive scope consumers ───────────────────────────────────────────────

  describe "reactive scope consumers via on_scope" do
    it "notifies the consumer when the scope cache is invalidated by a write" do
      notifications = []

      store.on_scope(Reminder, :open) { |_store_name, scope| notifications << scope }

      store.write(Reminder, key: "r1", title: "A", status: :open)
      # cache not yet warm — no notification
      expect(notifications).to be_empty

      # warm the cache
      store.scope(Reminder, :open)

      # mutate — scope cache invalidated → consumer fires
      store.write(Reminder, key: "r1", title: "A", status: :done)
      expect(notifications).to eq([:open])
    end

    it "fires consumers for both affected scopes on a status transition" do
      open_notifs = []
      done_notifs = []

      store.on_scope(Reminder, :open) { |_, sc| open_notifs << sc }
      store.on_scope(Reminder, :done) { |_, sc| done_notifs << sc }

      store.write(Reminder, key: "r1", title: "A", status: :open)

      # warm both scopes
      store.scope(Reminder, :open)
      store.scope(Reminder, :done)
      open_notifs.clear
      done_notifs.clear

      store.write(Reminder, key: "r1", title: "A", status: :done)

      expect(open_notifs).to eq([:open])
      expect(done_notifs).to eq([:done])
    end
  end

  # ── History (append-only) ──────────────────────────────────────────────────

  describe "History append / replay" do
    it "appends events and replays them in order" do
      store.append(TrackerLog, tracker_id: "t1", value: 7.0, notes: "morning")
      store.append(TrackerLog, tracker_id: "t1", value: 8.5)

      events = store.replay(TrackerLog)
      expect(events.length).to eq(2)
      expect(events.map(&:value)).to eq([7.0, 8.5])
    end

    it "returns an AppendReceipt that delegates to the typed event" do
      receipt = store.append(TrackerLog, tracker_id: "t1", value: 9.0)

      expect(receipt).to be_a(Igniter::Companion::AppendReceipt)
      expect(receipt.mutation_intent).to eq(:history_append)
      expect(receipt.fact_id).not_to be_nil
      expect(receipt.timestamp).to be_a(Float)
      expect(receipt.event).to be_a(TrackerLog)
      # delegation to event
      expect(receipt.value).to eq(9.0)
      expect(receipt.tracker_id).to eq("t1")
    end

    it "applies field defaults on replay" do
      store.append(TrackerLog, tracker_id: "t1", value: 5.0)
      event = store.replay(TrackerLog).first

      expect(event.notes).to be_nil  # default
    end

    it "supports time-filtered replay via since:" do
      store.append(TrackerLog, tracker_id: "t1", value: 1.0)
      sleep 0.01
      cutoff = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.append(TrackerLog, tracker_id: "t1", value: 2.0)

      recent = store.replay(TrackerLog, since: cutoff)
      expect(recent.map(&:value)).to eq([2.0])
    end

    it "replays all events without partition filter" do
      store.append(TrackerLog, tracker_id: "sleep",    value: 7.0)
      store.append(TrackerLog, tracker_id: "training", value: 45.0)
      store.append(TrackerLog, tracker_id: "sleep",    value: 8.5)

      all = store.replay(TrackerLog)
      expect(all.length).to eq(3)
    end
  end

  describe "History partition replay" do
    it "filters events by the declared partition_key value" do
      store.append(TrackerLog, tracker_id: "sleep",    value: 7.0)
      store.append(TrackerLog, tracker_id: "training", value: 45.0)
      store.append(TrackerLog, tracker_id: "sleep",    value: 8.5)

      sleep_logs    = store.replay(TrackerLog, partition: "sleep")
      training_logs = store.replay(TrackerLog, partition: "training")

      expect(sleep_logs.map(&:value)).to eq([7.0, 8.5])
      expect(training_logs.map(&:value)).to eq([45.0])
    end

    it "returns empty array for a partition with no events" do
      store.append(TrackerLog, tracker_id: "sleep", value: 7.0)
      expect(store.replay(TrackerLog, partition: "weight")).to be_empty
    end

    it "returns TrackerLog instances from partition replay" do
      store.append(TrackerLog, tracker_id: "sleep", value: 7.0)
      results = store.replay(TrackerLog, partition: "sleep")
      expect(results).to all(be_a(TrackerLog))
    end

    it "respects since: combined with partition:" do
      store.append(TrackerLog, tracker_id: "sleep", value: 6.0)
      sleep 0.01
      cutoff = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      store.append(TrackerLog, tracker_id: "sleep", value: 8.5)

      recent = store.replay(TrackerLog, partition: "sleep", since: cutoff)
      expect(recent.map(&:value)).to eq([8.5])
    end
  end

  describe "client-backed Ledger boundary" do
    def client_backed_store(changefeed: nil)
      ledger = Igniter::Ledger::LedgerStore.new(changefeed: changefeed)
      client = changefeed ? Igniter::LedgerClient.wrap(ledger) : Igniter::LedgerClient.wrap(ledger.protocol)
      described_class.new(client: client)
    end

    it "rejects mixed client and backend options" do
      client = Igniter::LedgerClient.wrap(Igniter::Ledger::LedgerStore.new.protocol)

      expect do
        described_class.new(client: client, backend: :file, path: "/tmp/companion-client.wal")
      end.to raise_error(ArgumentError, /client: cannot be combined/)
    end

    it "registers record and history descriptors through LedgerClient" do
      s = client_backed_store
      s.register(Reminder)
      s.register(TrackerLog)

      snapshot = s.descriptor_snapshot
      expect(snapshot[:stores]).to include(Reminder.store_name)
      expect(snapshot[:histories]).to include(TrackerLog.store_name)
    ensure
      s&.close
    end

    it "registers command and effect descriptors through LedgerClient" do
      s = client_backed_store
      s.register(CommandedReminder)

      commands = s.metadata_snapshot[:commands]
      effects = s.metadata_snapshot[:effects]

      expect(commands[:commanded_reminders][:complete]).to include(
        operation: :record_update,
        target_shape: :store,
        boundary: :app,
        mutation_intent: :record_update,
        changes: { status: :done },
        policy: { requires: [:reminder_complete], review: false }
      )
      expect(commands[:commanded_reminders][:review_complete]).to include(
        operation: :record_update,
        policy: { requires: [:reminder_complete], review: true }
      )
      expect(effects[:commanded_reminders][:complete]).to include(
        store_op: :store_write,
        write_kind: :update,
        lowers_to: :store_t,
        boundary: :app,
        source_operation: :record_update
      )
    ensure
      s&.close
    end

    it "exposes client-backed command and effect helpers without execution vocabulary" do
      s = client_backed_store
      s.register(CommandedReminder)

      expect(s._commands[:commanded_reminders][:complete]).to include(
        operation: :record_update,
        changes: { status: :done },
        policy: { requires: [:reminder_complete], review: false }
      )
      expect(s._effects[:commanded_reminders][:complete]).to include(
        store_op: :store_write,
        write_kind: :update
      )
      expect(s).not_to respond_to(:complete)
    ensure
      s&.close
    end

    it "builds client-backed command intents without writing records" do
      s = client_backed_store
      s.register(CommandedReminder)

      intent = s.command_intent(CommandedReminder, :complete,
        key: "r1",
        params: { completed_by: "user-1" })

      expect(intent).to be_a(Igniter::DurableModel::CommandIntent)
      expect(intent.to_h).to include(
        kind: :command_intent,
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        operation: :record_update,
        target_shape: :store,
        boundary: :app,
        changes: { status: :done },
        params: { completed_by: "user-1" },
        execution_allowed: false
      )
      expect(intent.effect).to include(store_op: :store_write, write_kind: :update, lowers_to: :store_t)
      expect(s.read(CommandedReminder, key: "r1")).to be_nil
    ensure
      s&.close
    end

    it "builds client-backed command operation plans without writing records" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      intent = s.command_intent(CommandedReminder, :complete,
        key: "r1",
        params: { changes: { title: "Buy oat milk" } })
      plan = s.command_operation_plan(intent)

      expect(plan).to be_a(Igniter::DurableModel::CommandOperationPlan)
      expect(plan).to be_ready
      expect(plan.to_h).to include(
        kind: :command_operation_plan,
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        operation: :record_update,
        status: :ready,
        target: { shape: :store, name: :commanded_reminders, key: "r1" },
        value: { id: "r1", title: "Buy oat milk", status: :done },
        execution_allowed: false
      )
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
    ensure
      s&.close
    end

    it "projects client-backed command activity events without exposing storage internals" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      intent = s.command_intent(CommandedReminder, :complete,
        key: "r1",
        metadata: { request_id: "req-1" })
      plan = s.command_operation_plan(intent)
      event = s.command_activity_event(plan, metadata: { actor: "user-1" })

      expect(event).to be_a(Igniter::DurableModel::CommandActivityEvent)
      expect(event.to_h).to include(
        kind: :command_activity_event,
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        operation: :record_update,
        status: :planned,
        intent_status: :ready,
        plan_status: :ready,
        target: { shape: :store, name: :commanded_reminders, key: "r1" },
        errors: [],
        store_fact_exposed: false,
        value_hash_exposed: false,
        execution_allowed: false
      )
      expect(event.metadata).to eq(request_id: "req-1", actor: "user-1")
      expect(event.to_h).not_to have_key(:fact_id)
      expect(event.to_h).not_to have_key(:value_hash)
      expect(event.to_h).not_to have_key(:value)
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
    ensure
      s&.close
    end

    it "explicitly appends client-backed command activity without applying command effects" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      intent = s.command_intent(CommandedReminder, :complete, key: "r1")
      plan = s.command_operation_plan(intent)
      event = s.command_activity_event(plan)
      receipt = s.append_command_activity(event)

      audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

      expect(receipt).to be_a(Igniter::DurableModel::CommandActivityReceipt)
      expect(receipt.to_h).to include(
        kind: :command_activity_receipt,
        status: :recorded,
        history: :command_activity,
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        activity_status: :planned,
        store_fact_exposed: false,
        value_hash_exposed: false,
        execution_allowed: false
      )
      expect(receipt).not_to respond_to(:fact_id)
      expect(receipt).not_to respond_to(:value_hash)
      expect(receipt).not_to respond_to(:causation)
      expect(audit.size).to eq(1)
      expect(audit.first).to be_a(Igniter::DurableModel::CommandActivity)
      expect(audit.first.status).to eq(:planned)
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
    ensure
      s&.close
    end

    it "applies client-backed command plans through the app boundary" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      intent = s.command_intent(CommandedReminder, :complete, key: "r1")
      plan = s.command_operation_plan(intent)
      receipt = s.apply_command(plan, audit: true)
      audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

      expect(receipt).to be_a(Igniter::DurableModel::CommandApplyReceipt)
      expect(receipt.to_h).to include(
        kind: :command_apply_receipt,
        status: :applied,
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        operation: :record_update,
        target: { shape: :store, name: :commanded_reminders, key: "r1" },
        mutation_intent: :record_write,
        activity_recorded: true,
        store_fact_exposed: false,
        value_hash_exposed: false,
        execution_boundary: :app
      )
      expect(receipt.to_h).not_to have_key(:fact_id)
      expect(receipt.to_h).not_to have_key(:value_hash)
      expect(receipt.to_h).not_to have_key(:causation)
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
      expect(audit.last.status).to eq(:applied)
    ensure
      s&.close
    end

    it "checks client-backed command policy decisions before app-boundary apply" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      intent = s.command_intent(CommandedReminder, :complete, key: "r1")
      plan = s.command_operation_plan(intent)
      denied = s.command_policy_decision(plan, actor: "user-1", capabilities: [])
      allowed = s.command_policy_decision(plan,
        actor: "user-1",
        capabilities: [:reminder_complete])

      expect(denied).to be_denied
      expect(denied.missing_capabilities).to eq([:reminder_complete])
      expect(allowed).to be_allowed
      expect(s.apply_command(plan, policy_decision: denied).status).to eq(:rejected)
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      expect(s.apply_command(plan, policy_decision: allowed).status).to eq(:applied)
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
    ensure
      s&.close
    end

    it "projects client-backed command lifecycle from activity history" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      intent = s.command_intent(CommandedReminder, :complete,
        key: "r1",
        metadata: { request_id: "req-1" })
      plan = s.command_operation_plan(intent)
      policy = s.command_policy_decision(plan,
        actor: "user-1",
        capabilities: [:reminder_complete])
      s.apply_command(plan, policy_decision: policy, audit: true)

      lifecycle = s.command_lifecycle(
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        request_id: "req-1"
      )

      expect(lifecycle).to be_a(Igniter::DurableModel::CommandLifecycle)
      expect(lifecycle).to be_applied
      expect(lifecycle.to_h).to include(
        status: :applied,
        owner: :commanded_reminders,
        command: :complete,
        subject_key: "r1",
        request_id: "req-1",
        actor: "user-1",
        policy_status: :allowed,
        apply_status: :applied,
        store_fact_exposed: false,
        value_hash_exposed: false
      )
      expect(lifecycle.to_h).not_to have_key(:fact_id)
      expect(lifecycle.latest_activity).not_to have_key(:value)
    ensure
      s&.close
    end

    it "runs client-backed command flow in preview and apply modes" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      preview = s.command_flow(CommandedReminder, :complete,
        key: "r1",
        actor: "user-1",
        capabilities: [:reminder_complete],
        metadata: { request_id: "req-client-preview" })
      applied = s.command_flow(CommandedReminder, :complete,
        key: "r1",
        actor: "user-1",
        capabilities: [:reminder_complete],
        metadata: { request_id: "req-client-apply" },
        mode: :apply,
        audit: true)

      expect(preview.status).to eq(:planned)
      expect(preview).not_to be_applied
      expect(preview.lifecycle.status).to eq(:planned)
      expect(applied.status).to eq(:applied)
      expect(applied).to be_applied
      expect(applied.lifecycle.status).to eq(:applied)
      expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
    ensure
      s&.close
    end

    it "builds client-backed temporal command flow slices" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

      s.command_flow(CommandedReminder, :complete,
        key: "r1",
        actor: "user-1",
        capabilities: [:reminder_complete],
        metadata: { request_id: "req-client-slice" },
        mode: :apply,
        audit: true)
      slice = s.command_flow_slice(
        owner: :commanded_reminders,
        command: :complete,
        actor: "user-1",
        status: :applied)

      expect(slice).to be_a(Igniter::DurableModel::CommandFlowSlice)
      expect(slice.size).to eq(1)
      expect(slice.status_counts).to eq(applied: 1)
      expect(slice.items.first).to include(
        request_id: "req-client-slice",
        actor: "user-1",
        status: :applied,
        command: :complete
      )
    ensure
      s&.close
    end

    it "evaluates client-backed command flow monitors over history" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
      s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)

      s.command_flow(CommandedReminder, :complete,
        key: "r1",
        actor: "user-1",
        capabilities: [:reminder_complete],
        metadata: { request_id: "req-client-monitor-1" },
        mode: :apply,
        audit: true)
      s.command_flow(CommandedReminder, :complete,
        key: "r2",
        actor: "user-2",
        capabilities: [],
        metadata: { request_id: "req-client-monitor-2" },
        mode: :apply,
        audit: true)

      result = s.command_flow_monitor(
        owner: :commanded_reminders,
        rules: [{
          name: :denials,
          metric: :status_count,
          status: :policy_denied,
          op: :>=,
          value: 1,
          severity: :warning
        }]
      )

      expect(result).to be_warning
      expect(result.alerts.size).to eq(1)
      expect(result.alerts.first).to include(name: :denials, actual: 1)
    ensure
      s&.close
    end

    it "evaluates client-backed command flow operational views" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
      s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)
      s.register_command_flow_view(:client_health,
        owner: :commanded_reminders,
        command: :complete,
        action_policy: { inspect: true },
        rules: [{
          name: :denials,
          metric: :status_count,
          status: :policy_denied,
          op: :>=,
          value: 1,
          severity: :warning
        }])

      s.command_flow(CommandedReminder, :complete,
        key: "r1",
        capabilities: [:reminder_complete],
        mode: :apply,
        audit: true)
      s.command_flow(CommandedReminder, :complete,
        key: "r2",
        capabilities: [],
        mode: :apply,
        audit: true)
      view = s.command_flow_view(:client_health)

      expect(view).to be_warning
      expect(view.slice.size).to eq(2)
      expect(view.monitor.alerts.first[:name]).to eq(:denials)
      expect(view.actionable?(:inspect)).to be true
    ensure
      s&.close
    end

    it "pins client-backed command flow operational views" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
      s.register_command_flow_view(:client_pin_health,
        owner: :commanded_reminders,
        command: :complete,
        action_policy: {
          mutate: :requires_pinned_horizon,
          required_capabilities: [:dispatch_review]
        })

      s.command_flow(CommandedReminder, :complete,
        key: "r1",
        capabilities: [:reminder_complete],
        mode: :apply,
        audit: true)
      pin = s.pin_command_flow_view(:client_pin_health,
        action: :mutate,
        capabilities: [:dispatch_review])

      expect(pin).to be_pinned
      expect(pin).to be_reproducible
      expect(pin.view).to be_reproducible
      expect(pin.receipt[:kind]).to eq(:command_flow_view_pin_receipt)
      expect(pin.receipt[:receipt_id]).to start_with("cfvp_")
    ensure
      s&.close
    end

    it "appends and replays client-backed command flow decisions" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.register_command_flow_view(:client_decision_health,
        owner: :commanded_reminders,
        action_policy: {
          inspect: true,
          required_capabilities: [:dispatch_review]
        })
      pin = s.pin_command_flow_view(:client_decision_health,
        action: :inspect,
        actor: "dispatcher-1",
        capabilities: [:dispatch_review],
        metadata: { request_id: "client-pin" })

      receipt = s.append_command_flow_decision(pin,
        metadata: { persisted_by: :client_spec })
      decisions = s.command_flow_decisions(
        owner: :commanded_reminders,
        view_name: :client_decision_health,
        action: :inspect,
        actor: "dispatcher-1",
        status: :pinned,
        receipt_id: pin.receipt[:receipt_id],
        decision_receipt_id: receipt.decision_receipt_id
      )
      review = s.command_flow_decision_review(
        owner: :commanded_reminders,
        view_name: :client_decision_health,
        rules: [{
          name: :pinned,
          metric: :status_count,
          status: :pinned,
          op: :>=,
          value: 1
        }]
      )

      expect(receipt).to be_appended
      expect(receipt.receipt_id).to eq(pin.receipt[:receipt_id])
      expect(receipt.decision_receipt_id).to start_with("cfd_")
      expect(decisions.size).to eq(1)
      expect(decisions.first).to be_a(Igniter::DurableModel::CommandFlowDecision)
      expect(decisions.first.decision_receipt_id).to eq(receipt.decision_receipt_id)
      expect(decisions.first.metadata).to include(
        request_id: "client-pin",
        persisted_by: :client_spec
      )
      expect(review).to be_warning
      expect(review.findings.first[:name]).to eq(:pinned)
    ensure
      s&.close
    end

    it "builds client-backed command flow evidence profiles" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.register_command_flow_view(:client_profile_health,
        owner: :commanded_reminders,
        action_policy: {
          inspect: true,
          required_capabilities: [:dispatch_review]
        })
      pin = s.pin_command_flow_view(:client_profile_health,
        action: :inspect,
        actor: "dispatcher-1",
        capabilities: [:dispatch_review])
      s.append_command_flow_decision(pin)

      profile = s.command_flow_evidence_profile(
        view_name: :client_profile_health,
        action: :inspect,
        actor: "dispatcher-1",
        capabilities: [:dispatch_review],
        decision_rules: [{
          name: :pinned,
          metric: :status_count,
          status: :pinned,
          op: :>=,
          value: 1
        }]
      )

      expect(profile).to be_warning
      expect(profile.view_name).to eq(:client_profile_health)
      expect(profile.pin[:status]).to eq(:pinned)
      expect(profile.review[:status]).to eq(:warning)
      expect(profile.packets.map { |packet| packet[:kind] }).to include(
        :command_flow_view_evidence,
        :command_flow_pin_evidence,
        :command_flow_decision_review_evidence,
        :command_flow_decision_evidence
      )
    ensure
      s&.close
    end

    it "exports client-backed command flow evidence profiles" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.register_command_flow_view(:client_export_health,
        owner: :commanded_reminders,
        action_policy: { inspect: true })

      export = s.command_flow_evidence_export(
        view_name: :client_export_health,
        action: :inspect,
        privacy: :summary_only)

      expect(export).to be_a(Igniter::DurableModel::CommandFlowEvidenceExport)
      expect(export.export_id).to start_with("cfe_")
      expect(export.canonical_json).to include("command_flow_evidence_export_content")
      expect(export.profile).not_to have_key(:view)
      expect(export.diagnostics.map { |diagnostic| diagnostic[:code] })
        .to include(:evidence_payloads_omitted)
    ensure
      s&.close
    end

    it "archives and verifies client-backed command flow evidence exports" do
      s = client_backed_store
      s.register(CommandedReminder)
      s.register_command_flow_view(:client_archive_health,
        owner: :commanded_reminders,
        action_policy: { inspect: true })
      export = s.command_flow_evidence_export(
        view_name: :client_archive_health,
        action: :inspect,
        privacy: :summary_only)

      verification = s.verify_command_flow_evidence_export(export)
      receipt = s.archive_command_flow_evidence_export(export,
        metadata: { case_id: "client-archive" })
      archives = s.command_flow_evidence_archives(
        owner: :commanded_reminders,
        view_name: :client_archive_health,
        export_id: export.export_id,
        content_hash: export.content_hash,
        privacy: :summary_only
      )

      expect(verification).to be_valid
      expect(receipt).to be_archived
      expect(receipt.archive_receipt_id).to start_with("cfea_")
      expect(archives.size).to eq(1)
      expect(archives.first.canonical_json).to eq(export.canonical_json)
      expect(archives.first.metadata).to include(case_id: "client-archive")
    ensure
      s&.close
    end

    it "writes and reads a Record through LedgerClient results" do
      s = client_backed_store
      s.register(Reminder)

      receipt = s.write(Reminder, key: "r1", title: "Buy milk", status: :open)
      record = s.read(Reminder, key: "r1")

      expect(receipt).to be_a(Igniter::Companion::WriteReceipt)
      expect(receipt.fact_id).not_to be_nil
      expect(receipt.value_hash).not_to be_nil
      expect(record).to be_a(Reminder)
      expect(record.title).to eq("Buy milk")
      expect(record.status).to eq(:open)
    ensure
      s&.close
    end

    it "appends and replays History events without partition filtering" do
      s = client_backed_store
      s.register(TrackerLog)

      receipt = s.append(TrackerLog, tracker_id: "sleep", value: 7.0)
      s.append(TrackerLog, tracker_id: "training", value: 45.0)

      events = s.replay(TrackerLog)
      expect(receipt).to be_a(Igniter::Companion::AppendReceipt)
      expect(receipt.fact_id).not_to be_nil
      expect(receipt.value_hash).not_to be_nil
      expect(events.map(&:value)).to eq([7.0, 45.0])
      expect(events).to all(be_a(TrackerLog))
    ensure
      s&.close
    end

    it "returns nil for missing client-backed reads" do
      s = client_backed_store
      s.register(Reminder)

      expect(s.read(Reminder, key: "missing")).to be_nil
    ensure
      s&.close
    end

    it "queries declared Record scopes through LedgerClient items" do
      s = client_backed_store
      s.register(Reminder)

      s.write(Reminder, key: "r1", title: "A", status: :open)
      s.write(Reminder, key: "r2", title: "B", status: :done)
      s.write(Reminder, key: "r3", title: "C", status: :open)

      results = s.scope(Reminder, :open)

      expect(results.map(&:key)).to contain_exactly("r1", "r3")
      expect(results.map(&:title)).to contain_exactly("A", "C")
      expect(results).to all(be_a(Reminder))
    ensure
      s&.close
    end

    it "queries client-backed scopes at a past point in time" do
      s = client_backed_store
      s.register(Reminder)

      s.write(Reminder, key: "r1", title: "A", status: :open)
      sleep 0.01
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      s.write(Reminder, key: "r1", title: "A", status: :done)

      at_checkpoint = s.scope(Reminder, :open, as_of: checkpoint)
      current = s.scope(Reminder, :open)

      expect(at_checkpoint.map(&:key)).to eq(["r1"])
      expect(current).to be_empty
    ensure
      s&.close
    end

    it "fails clearly for unknown client-backed scopes" do
      s = client_backed_store
      s.register(Reminder)

      expect { s.scope(Reminder, :archived) }
        .to raise_error(ArgumentError, /scope=:archived/)
    ensure
      s&.close
    end

    it "subscribes to client-backed scope changes and yields refreshed records" do
      s = client_backed_store(changefeed: Igniter::Store::ChangefeedBuffer.new)
      s.register(Reminder)
      notifications = []

      subscription = s.on_scope(Reminder, :open) do |store_name, records|
        notifications << [store_name, records.map(&:title)]
      end

      s.write(Reminder, key: "r1", title: "A", status: :open)
      sleep 0.05

      expect(notifications).to include([:reminders, ["A"]])
      subscription.close
      subscription.close
    ensure
      subscription&.close
      s&.close
    end

    it "fails clearly for unknown client-backed scope subscriptions" do
      s = client_backed_store(changefeed: Igniter::Store::ChangefeedBuffer.new)
      s.register(Reminder)

      expect { s.on_scope(Reminder, :archived) { nil } }
        .to raise_error(ArgumentError, /scope=:archived/)
    ensure
      s&.close
    end

    it "supports client-backed partition replay" do
      s = client_backed_store
      s.register(TrackerLog)

      s.append(TrackerLog, tracker_id: "sleep", value: 7.0)
      s.append(TrackerLog, tracker_id: "training", value: 45.0)
      s.append(TrackerLog, tracker_id: "sleep", value: 8.5)

      events = s.replay(TrackerLog, partition: "sleep")

      expect(events.map(&:value)).to eq([7.0, 8.5])
      expect(events).to all(be_a(TrackerLog))
    ensure
      s&.close
    end

    it "supports client-backed partition replay with since: and as_of:" do
      s = client_backed_store
      s.register(TrackerLog)

      s.append(TrackerLog, tracker_id: "sleep", value: 6.0)
      sleep 0.01
      lower = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      s.append(TrackerLog, tracker_id: "sleep", value: 7.0)
      sleep 0.01
      upper = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      s.append(TrackerLog, tracker_id: "sleep", value: 8.5)
      s.append(TrackerLog, tracker_id: "training", value: 45.0)

      events = s.replay(TrackerLog, partition: "sleep", since: lower, as_of: upper)

      expect(events.map(&:value)).to eq([7.0])
    ensure
      s&.close
    end

    it "auto-wires supported client-backed one-to-many relations during register" do
      s = client_backed_store
      s.register(BlogPost)

      expect(s._relations.keys).to include(:comments_by_post, :tags_by_post)
      expect(s._relations.keys).not_to include(:author_ref)
      expect(s._relations[:comments_by_post]).to include(
        source: :blog_comments,
        partition: :post_id,
        target: :blog_posts,
        index_store: :__rel_comments_by_post
      )
    ensure
      s&.close
    end

    it "supports client-backed typed relation resolve" do
      s = client_backed_store
      s.register(BlogPost)
      s.register(BlogComment)

      s.write(BlogComment, key: "c1", body: "Nice", post_id: "p1")
      s.write(BlogComment, key: "c2", body: "Other", post_id: "p2")
      s.write(BlogComment, key: "c3", body: "Great", post_id: "p1")

      comments = s.resolve(:comments_by_post, from: "p1")

      expect(comments).to all(be_a(BlogComment))
      expect(comments.map(&:key)).to contain_exactly("c1", "c3")
      expect(comments.map(&:body)).to contain_exactly("Nice", "Great")
    ensure
      s&.close
    end

    it "supports client-backed relation resolve at a past point in time" do
      s = client_backed_store
      s.register(BlogPost)
      s.register(BlogComment)

      s.write(BlogComment, key: "c1", body: "Early", post_id: "p1")
      sleep 0.01
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.01
      s.write(BlogComment, key: "c2", body: "Later", post_id: "p1")

      past = s.resolve(:comments_by_post, from: "p1", as_of: checkpoint)
      current = s.resolve(:comments_by_post, from: "p1")

      expect(past.map(&:body)).to eq(["Early"])
      expect(current.map(&:body)).to contain_exactly("Early", "Later")
    ensure
      s&.close
    end

    it "returns [] for unknown client-backed relation partitions" do
      s = client_backed_store
      s.register(BlogPost)
      s.register(BlogComment)

      expect(s.resolve(:comments_by_post, from: "missing")).to eq([])
    ensure
      s&.close
    end

    it "fails clearly for unknown client-backed relations" do
      s = client_backed_store

      expect { s.resolve(:missing_relation, from: "p1") }
        .to raise_error(ArgumentError, /No relation registered/)
    ensure
      s&.close
    end

    it "supports explicit client-backed register_relation" do
      s = client_backed_store
      s.register(BlogComment)
      s.register_relation(:manual_comments_by_post,
        source: BlogComment,
        partition: :post_id,
        target: :blog_posts)

      s.write(BlogComment, key: "c1", body: "Manual", post_id: "p1")
      comments = s.resolve(:manual_comments_by_post, from: "p1")

      expect(comments.first).to be_a(BlogComment)
      expect(comments.first.body).to eq("Manual")
    ensure
      s&.close
    end

    it "supports client-backed projection descriptor registration and snapshots" do
      s = client_backed_store

      s.register_projection(:tracker_dashboard,
        reads: [:trackers, :tracker_logs],
        relations: [:logs_by_tracker],
        consumer_hint: :contract_node,
        reactive: true)

      projection = s._projections[:tracker_dashboard]
      expect(projection).to include(
        name: :tracker_dashboard,
        reads: [:trackers, :tracker_logs],
        relations: [:logs_by_tracker],
        consumer_hint: :contract_node,
        reactive: true,
        store_count: 2,
        relation_count: 1
      )
    ensure
      s&.close
    end

    it "returns client-backed scatter metadata from the remote snapshot" do
      s = client_backed_store
      s.register(BlogPost)
      s.register(BlogComment)

      scatters = s._scatters

      expect(scatters).not_to be_empty
      expect(scatters).to include(include(
        source_store: :blog_comments,
        partition_by: :post_id,
        target_store: :__rel_comments_by_post,
        has_rule: true
      ))
    ensure
      s&.close
    end

    it "keeps client-backed register_scatter unsupported" do
      s = client_backed_store

      expect do
        s.register_scatter(Reminder,
          partition_by: :status,
          target_store: :status_index,
          rule: ->(_partition, _existing, _fact) { {} })
      end.to raise_error(NotImplementedError, /scatter registration/)
    ensure
      s&.close
    end

    it "supports client-backed causation chains" do
      s = client_backed_store
      s.register(Reminder)

      s.write(Reminder, key: "r1", title: "One", status: :open)
      s.write(Reminder, key: "r1", title: "Two", status: :done)

      chain = s.causation_chain(Reminder, key: "r1")

      expect(chain.length).to eq(2)
      expect(chain.first[:causation]).to be_nil
      expect(chain.last[:causation]).not_to be_nil
    ensure
      s&.close
    end

    it "supports client-backed lineage introspection" do
      s = client_backed_store
      s.register(Reminder)

      s.write(Reminder, key: "r1", title: "One", status: :open)

      lineage = s.lineage(Reminder, key: "r1")

      expect(lineage[:subject]).to eq(store: :reminders, key: "r1")
      expect(lineage[:depth]).to eq(1)
      expect(lineage[:proof_hash]).to be_a(String)
    ensure
      s&.close
    end
  end

  # ── Manifest-generated classes ─────────────────────────────────────────────

  RECORD_MANIFEST = {
    storage: { shape: :store, name: :gen_items, key: :id },
    fields: [
      { name: :id,         attributes: {} },
      { name: :title,      attributes: { type: :string } },
      { name: :status,     attributes: { type: :enum, values: %i[open done], default: :open } },
      { name: :due,        attributes: {} },
      { name: :created_at, attributes: { type: :datetime } }
    ],
    scopes: [
      { name: :open, attributes: { where: { status: :open } } },
      { name: :done, attributes: { where: { status: :done } } }
    ]
  }.freeze

  HISTORY_MANIFEST = {
    storage: { shape: :history, name: :gen_events, key: :tracker_id },
    history: { kind: :history, key: :tracker_id },
    fields: [
      { name: :tracker_id, attributes: {} },
      { name: :value,      attributes: {} },
      { name: :notes,      attributes: { default: nil } }
    ]
  }.freeze

  describe "Record.from_manifest" do
    subject(:klass) { Igniter::Companion::Record.from_manifest(RECORD_MANIFEST) }

    it "returns a class that includes Record" do
      expect(klass.ancestors).to include(Igniter::Companion::Record)
    end

    it "uses storage.name from manifest when store: is omitted" do
      expect(klass.store_name).to eq(:gen_items)
    end

    it "overrides store_name when store: is given explicitly" do
      override = Igniter::Companion::Record.from_manifest(RECORD_MANIFEST, store: :custom)
      expect(override.store_name).to eq(:custom)
    end

    it "raises when manifest has no storage.name and store: is omitted" do
      nameless = { storage: { shape: :store, key: :id }, fields: [], scopes: [] }
      expect { Igniter::Companion::Record.from_manifest(nameless) }
        .to raise_error(ArgumentError, /store:/)
    end

    it "declares all manifest fields as attributes" do
      expect(klass._fields.keys).to eq(%i[id title status due created_at])
    end

    it "applies field defaults declared in the manifest" do
      obj = klass.new(key: "x", id: "x", title: "T")
      expect(obj.status).to eq(:open)
    end

    it "declares all manifest scopes" do
      expect(klass._scopes.keys).to eq(%i[open done])
    end

    it "scope filters map from manifest where: attributes" do
      expect(klass._scopes[:open][:filters]).to eq({ status: :open })
    end

    it "works end-to-end with Store write/read/scope" do
      s = Igniter::Companion::Store.new
      s.register(klass)

      s.write(klass, key: "r1", id: "r1", title: "Foo", status: :open)
      s.write(klass, key: "r2", id: "r2", title: "Bar", status: :done)

      expect(s.read(klass, key: "r1").title).to eq("Foo")
      expect(s.scope(klass, :open).map(&:title)).to eq(["Foo"])
      expect(s.scope(klass, :done).map(&:title)).to eq(["Bar"])
    ensure
      s&.close
    end
  end

  describe "History.from_manifest" do
    subject(:klass) { Igniter::Companion::History.from_manifest(HISTORY_MANIFEST) }

    it "returns a class that includes History" do
      expect(klass.ancestors).to include(Igniter::Companion::History)
    end

    it "uses storage.name from manifest when store: is omitted" do
      expect(klass.store_name).to eq(:gen_events)
    end

    it "sets partition_key from history.key in manifest" do
      expect(klass._partition_key).to eq(:tracker_id)
    end

    it "declares all manifest fields" do
      expect(klass._fields.keys).to eq(%i[tracker_id value notes])
    end

    it "works end-to-end with Store append/replay/partition" do
      s = Igniter::Companion::Store.new
      s.append(klass, tracker_id: "sleep",    value: 7.0)
      s.append(klass, tracker_id: "training", value: 45.0)
      s.append(klass, tracker_id: "sleep",    value: 8.5)

      expect(s.replay(klass).length).to eq(3)
      expect(s.replay(klass, partition: "sleep").map(&:value)).to eq([7.0, 8.5])
    ensure
      s&.close
    end
  end

  describe "Igniter::Companion.from_manifest" do
    it "returns a Record class for shape: :store using manifest name" do
      klass = Igniter::Companion.from_manifest(RECORD_MANIFEST)
      expect(klass.ancestors).to include(Igniter::Companion::Record)
      expect(klass.store_name).to eq(:gen_items)
    end

    it "returns a History class for shape: :history using manifest name" do
      klass = Igniter::Companion.from_manifest(HISTORY_MANIFEST)
      expect(klass.ancestors).to include(Igniter::Companion::History)
      expect(klass.store_name).to eq(:gen_events)
    end

    it "overrides manifest name when store: is given" do
      klass = Igniter::Companion.from_manifest(RECORD_MANIFEST, store: :override)
      expect(klass.store_name).to eq(:override)
    end

    it "raises ArgumentError for unknown shape" do
      bad_manifest = { storage: { shape: :graph } }
      expect { Igniter::Companion.from_manifest(bad_manifest, store: :x) }
        .to raise_error(ArgumentError, /Unknown storage shape/)
    end
  end

  # ── Relation auto-wire (Belt 10) ──────────────────────────────────────────

  # Schema classes used only in this section to avoid polluting global fixtures.
  BlogPost = Class.new do
    include Igniter::Companion::Record
    store_name :blog_posts
    field :title
    relation :comments_by_post, kind: :event_owner, to: :blog_comments,
             join: { id: :post_id }, cardinality: :one_to_many
    relation :tags_by_post,     kind: :ownership, to: :blog_tags,
             join: { id: :post_id }, cardinality: :one_to_many
    relation :author_ref,       kind: :reference, to: :users,
             join: { author_id: :id }, cardinality: :many_to_one  # should NOT be auto-wired
  end

  BlogComment = Class.new do
    include Igniter::Companion::Record
    store_name :blog_comments
    field :body
    field :post_id
  end

  describe "Companion::Store register — relation auto-wire" do
    subject(:store) do
      s = described_class.new
      s.register(BlogPost)
      s
    end

    it "auto-wires one_to_many/event_owner relation on register" do
      snap = store._relations
      expect(snap.keys).to include(:comments_by_post)
    end

    it "auto-wires one_to_many/ownership relation on register" do
      snap = store._relations
      expect(snap.keys).to include(:tags_by_post)
    end

    it "does NOT auto-wire many_to_one/reference relations" do
      snap = store._relations
      expect(snap.keys).not_to include(:author_ref)
    end

    it "resolves an empty array before any comments are written" do
      expect(store.resolve(:comments_by_post, from: "p1")).to eq([])
    end

    it "resolve returns source values after a comment is written" do
      store.write(BlogComment, key: "c1", body: "Great post!", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result.size).to eq(1)
      # write auto-registers BlogComment, so typed BlogComment instances are returned
      expect(result.first.body).to eq("Great post!")
    end

    it "accumulates multiple comments for the same post" do
      store.write(BlogComment, key: "c1", body: "First",  post_id: "p1")
      store.write(BlogComment, key: "c2", body: "Second", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result.size).to eq(2)
      expect(result.map(&:body)).to contain_exactly("First", "Second")
    end

    it "keeps per-post indexes separate" do
      store.write(BlogComment, key: "c1", body: "On P1", post_id: "p1")
      store.write(BlogComment, key: "c2", body: "On P2", post_id: "p2")
      expect(store.resolve(:comments_by_post, from: "p1").size).to eq(1)
      expect(store.resolve(:comments_by_post, from: "p2").size).to eq(1)
    end

    it "returns latest comment value after update" do
      store.write(BlogComment, key: "c1", body: "old", post_id: "p1")
      store.write(BlogComment, key: "c1", body: "new", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result.size).to eq(1)
      expect(result.first.body).to eq("new")
    end

    it "_relations snapshot includes index_store key" do
      snap = store._relations
      expect(snap[:comments_by_post][:index_store]).to eq(:__rel_comments_by_post)
    end
  end

  describe "Companion::Store register — idempotency" do
    it "calling register twice with the same class is a no-op (no duplicate rules)" do
      s = described_class.new
      s.register(BlogPost)
      s.register(BlogPost)

      # Only one scatter rule per relation, not two
      scatter = s.instance_variable_get(:@inner).schema_graph.scatter_snapshot
      comments_scatters = scatter.select { |r| r[:source_store] == :blog_comments }
      expect(comments_scatters.size).to eq(1)
    ensure
      s&.close
    end

    it "returns self (chainable)" do
      s = described_class.new
      expect(s.register(BlogPost)).to be(s)
    ensure
      s&.close
    end
  end

  describe "Companion::Store register — schema class without _relations" do
    it "does not raise when schema_class has no _relations (plain Reminder)" do
      s = described_class.new
      expect { s.register(Reminder) }.not_to raise_error
    ensure
      s&.close
    end
  end

  # ── Belt 12: auto-register on write + time-travel resolve ─────────────────

  describe "auto-register schema class on write (Belt 12)" do
    subject(:store) do
      s = described_class.new
      s.register(BlogPost)   # registers BlogPost + wires the relation
      # BlogComment NOT explicitly registered
      s
    end

    it "write(BlogComment, ...) registers the class for typed resolve" do
      store.write(BlogComment, key: "c1", body: "Auto-registered!", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result.first).to be_a(BlogComment)
    end

    it "typed instance has correct fields after auto-register" do
      store.write(BlogComment, key: "c1", body: "Hello", post_id: "p1")
      comment = store.resolve(:comments_by_post, from: "p1").first
      expect(comment.body).to    eq("Hello")
      expect(comment.key).to     eq("c1")
      expect(comment.post_id).to eq("p1")
    end

    it "auto-register is idempotent across multiple writes" do
      store.write(BlogComment, key: "c1", body: "One",   post_id: "p1")
      store.write(BlogComment, key: "c2", body: "Two",   post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result).to all(be_a(BlogComment))
      expect(result.size).to eq(2)
    end
  end

  describe "resolve with as_of: (Belt 12 time-travel)" do
    subject(:store) do
      s = described_class.new
      s.register(BlogPost)
      s.register(BlogComment)
      s
    end

    it "returns the relation state at a past checkpoint" do
      store.write(BlogComment, key: "c1", body: "Early",  post_id: "p1")
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      store.write(BlogComment, key: "c2", body: "Later",  post_id: "p1")

      past    = store.resolve(:comments_by_post, from: "p1", as_of: checkpoint)
      current = store.resolve(:comments_by_post, from: "p1")

      expect(past.size).to    eq(1)
      expect(past.first).to   be_a(BlogComment)
      expect(past.first.body).to eq("Early")
      expect(current.size).to eq(2)
    end

    it "returns [] when partition had no entries before the checkpoint" do
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      store.write(BlogComment, key: "c1", body: "Post", post_id: "p1")

      expect(store.resolve(:comments_by_post, from: "p1", as_of: checkpoint)).to eq([])
    end

    it "returns the source value at the past checkpoint, not the current value" do
      store.write(BlogComment, key: "c1", body: "v1", post_id: "p1")
      sleep 0.005
      checkpoint = Process.clock_gettime(Process::CLOCK_REALTIME)
      sleep 0.005
      store.write(BlogComment, key: "c1", body: "v2", post_id: "p1")

      past = store.resolve(:comments_by_post, from: "p1", as_of: checkpoint)
      expect(past.first.body).to eq("v1")
    end
  end

  # ── Portable field types ───────────────────────────────────────────────────

  describe "portable field types" do
    subject(:klass) { Igniter::Companion::Record.from_manifest(RECORD_MANIFEST) }

    it "stores type: in _fields metadata" do
      expect(klass._fields[:title][:type]).to eq(:string)
      expect(klass._fields[:created_at][:type]).to eq(:datetime)
    end

    it "stores values: for enum fields" do
      expect(klass._fields[:status][:type]).to eq(:enum)
      expect(klass._fields[:status][:values]).to eq(%i[open done])
    end

    it "stores nil type for untyped fields" do
      expect(klass._fields[:id][:type]).to be_nil
      expect(klass._fields[:due][:type]).to be_nil
    end

    it "combines type with default" do
      expect(klass._fields[:status][:default]).to eq(:open)
      expect(klass._fields[:status][:type]).to eq(:enum)
    end

    it "supports type: kwarg on hand-written field declarations" do
      klass = Class.new do
        include Igniter::Companion::Record
        store_name :typed_test
        field :score,  type: :float
        field :active, type: :boolean
        field :label,  type: :string, default: "n/a"
      end
      expect(klass._fields[:score][:type]).to eq(:float)
      expect(klass._fields[:active][:type]).to eq(:boolean)
      expect(klass._fields[:label][:default]).to eq("n/a")
    end

    it "typed field round-trips correctly through Store write/read" do
      s = Igniter::Companion::Store.new
      s.register(klass)

      s.write(klass, key: "t1", id: "t1", title: "Hello", status: :open,
              created_at: "2026-04-30")
      record = s.read(klass, key: "t1")

      expect(record.title).to eq("Hello")
      expect(record.status).to eq(:open)
      expect(record.created_at).to eq("2026-04-30")
    ensure
      s&.close
    end
  end

  # ── Typed resolve (Belt 11) ────────────────────────────────────────────────

  describe "Companion::Store#resolve — typed records (Belt 11)" do
    # Store where both BlogPost and BlogComment are registered.
    subject(:store) do
      s = described_class.new
      s.register(BlogPost)
      s.register(BlogComment)
      s
    end

    it "returns typed BlogComment instances when source class is registered" do
      store.write(BlogComment, key: "c1", body: "Hello", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result.first).to be_a(BlogComment)
    end

    it "typed instance has the correct field values" do
      store.write(BlogComment, key: "c1", body: "Nice article", post_id: "p1")
      comment = store.resolve(:comments_by_post, from: "p1").first
      expect(comment.body).to   eq("Nice article")
      expect(comment.post_id).to eq("p1")
    end

    it "typed instance has a key" do
      store.write(BlogComment, key: "c1", body: "Hi", post_id: "p1")
      comment = store.resolve(:comments_by_post, from: "p1").first
      expect(comment.key).to eq("c1")
    end

    it "returns the latest typed value after an update" do
      store.write(BlogComment, key: "c1", body: "v1", post_id: "p1")
      store.write(BlogComment, key: "c1", body: "v2", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result.size).to eq(1)
      expect(result.first.body).to eq("v2")
    end

    it "returns multiple typed instances for different comment keys" do
      store.write(BlogComment, key: "c1", body: "First",  post_id: "p1")
      store.write(BlogComment, key: "c2", body: "Second", post_id: "p1")
      result = store.resolve(:comments_by_post, from: "p1")
      expect(result).to all(be_a(BlogComment))
      expect(result.map(&:body)).to contain_exactly("First", "Second")
    end

    it "returns [] for an unknown partition value" do
      expect(store.resolve(:comments_by_post, from: "p99")).to eq([])
    end

    it "raises ArgumentError for an unregistered relation" do
      expect { store.resolve(:nonexistent, from: "p1") }
        .to raise_error(ArgumentError, /No relation registered/)
    end

    context "when source class is NOT registered" do
      subject(:store) do
        # Only BlogPost registered, BlogComment is not
        s = described_class.new
        s.register(BlogPost)
        s
      end

      it "falls back to raw Hash values when source class is not in schema registry" do
        # Write directly via the inner store to bypass companion write
        store.instance_variable_get(:@inner).write(
          store: :blog_comments, key: "c1",
          value: { body: "raw write", post_id: "p1" }
        )
        result = store.resolve(:comments_by_post, from: "p1")
        # The scatter triggers and builds the index since BlogPost registered BlogComment relation
        expect(result).not_to be_empty
        expect(result.first).to be_a(Hash)
        expect(result.first[:body]).to eq("raw write")
      end
    end
  end

  # ── Protocol adoption (OP1/OP2 visibility) ───────────────────────────────────

  describe "Companion::Store — protocol adoption (OP1/OP2)" do
    describe "#metadata_snapshot" do
      it "returns a Hash with schema_version: 1" do
        snap = store.metadata_snapshot
        expect(snap).to be_a(Hash)
        expect(snap[:schema_version]).to eq(1)
      end

      it "includes :stores key with Reminder's store name after register" do
        snap = store.metadata_snapshot
        expect(snap[:stores]).to include(Reminder.store_name)
      end

      it "includes :histories key" do
        s = described_class.new
        s.register(TrackerLog)
        snap = s.metadata_snapshot
        expect(snap[:histories]).to include(TrackerLog.store_name)
      ensure
        s&.close
      end

      it "includes access_paths, relations, projections, commands, effects, scatters, retention keys" do
        snap = store.metadata_snapshot
        expect(snap).to have_key(:access_paths)
        expect(snap).to have_key(:relations)
        expect(snap).to have_key(:projections)
        expect(snap).to have_key(:commands)
        expect(snap).to have_key(:effects)
        expect(snap).to have_key(:scatters)
        expect(snap).to have_key(:retention)
      end

      it "includes embedded command and effect descriptors after register" do
        s = described_class.new
        s.register(CommandedReminder)

        commands = s.metadata_snapshot[:commands]
        effects = s.metadata_snapshot[:effects]

        expect(CommandedReminder._commands[:complete]).to include(
          operation: :record_update,
          changes: { status: :done }
        )
        expect(CommandedReminder._effects[:complete]).to include(
          store_op: :store_write,
          write_kind: :update,
          lowers_to: :store_t,
          source_operation: :record_update
        )
        expect(commands[:commanded_reminders][:complete]).to include(
          operation: :record_update,
          target_shape: :store,
          boundary: :app,
          mutation_intent: :record_update,
          changes: { status: :done }
        )
        expect(effects[:commanded_reminders][:complete]).to include(
          store_op: :store_write,
          write_kind: :update,
          lowers_to: :store_t,
          boundary: :app,
          source_operation: :record_update
        )
      ensure
        s&.close
      end

      it "builds embedded command intents from command and effect metadata" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          params: { completed_by: "user-1" },
          metadata: { request_id: "req-1" })

        expect(intent).to be_frozen
        expect(intent[:owner]).to eq(:commanded_reminders)
        expect(intent.to_h).to include(
          schema_version: 1,
          kind: :command_intent,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          operation: :record_update,
          target_shape: :store,
          boundary: :app,
          changes: { status: :done },
          params: { completed_by: "user-1" },
          metadata: { request_id: "req-1" },
          execution_allowed: false
        )
        expect(intent.effect).to include(
          store_op: :store_write,
          write_kind: :update,
          lowers_to: :store_t,
          source_operation: :record_update
        )
        expect(intent.to_activity_event).to include(
          kind: :command_intent,
          owner: :commanded_reminders,
          command: :complete,
          status: :intended
        )
        expect(s.read(CommandedReminder, key: "r1")).to be_nil
      ensure
        s&.close
      end

      it "requires key for record_update command intents" do
        s = described_class.new
        s.register(CommandedReminder)

        expect { s.command_intent(CommandedReminder, :complete) }
          .to raise_error(ArgumentError, /requires key/)
      ensure
        s&.close
      end

      it "raises clearly for unknown command intents" do
        s = described_class.new
        s.register(CommandedReminder)

        expect { s.command_intent(CommandedReminder, :missing, key: "r1") }
          .to raise_error(ArgumentError, /Unknown command :missing/)
      ensure
        s&.close
      end

      it "allows record_append and history_append intents without keys" do
        s = described_class.new
        s.register(CommandedReminder)

        append_intent = s.command_intent(CommandedReminder, :draft)
        history_intent = s.command_intent(CommandedReminder, :audit, params: { actor: "user-1" })

        expect(append_intent.subject_key).to be_nil
        expect(append_intent.effect).to include(store_op: :store_write, write_kind: :insert)
        expect(history_intent.subject_key).to be_nil
        expect(history_intent.operation).to eq(:history_append)
        expect(history_intent.effect).to include(store_op: :store_append, write_kind: :append)
        expect(history_intent.event).to eq(event: :audited)
      ensure
        s&.close
      end

      it "normalizes string command metadata keys in command intents" do
        s = described_class.new
        s.register(StringCommandReminder)

        intent = s.command_intent(StringCommandReminder, :complete, key: "r1")

        expect(intent.command).to eq(:complete)
        expect(intent.operation).to eq(:record_update)
        expect(intent.changes).to eq(status: "done")
        expect(intent.effect).to include(
          store_op: :store_write,
          write_kind: :update,
          source_operation: :record_update
        )
      ensure
        s&.close
      end

      it "builds embedded record_update operation plans without writing" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          params: { changes: { title: "Buy oat milk" } },
          metadata: { request_id: "req-1" })
        plan = s.command_operation_plan(intent)

        expect(plan).to be_frozen
        expect(plan).to be_ready
        expect(plan[:owner]).to eq(:commanded_reminders)
        expect(plan.to_h).to include(
          schema_version: 1,
          kind: :command_operation_plan,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          operation: :record_update,
          status: :ready,
          target: { shape: :store, name: :commanded_reminders, key: "r1" },
          value: { id: "r1", title: "Buy oat milk", status: :done },
          metadata: { request_id: "req-1" },
          execution_allowed: false
        )
        expect(plan.effect).to include(store_op: :store_write, write_kind: :update)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "returns invalid operation plans when record_update target is missing" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete, key: "missing")
        plan = s.command_operation_plan(intent)

        expect(plan).to be_invalid
        expect(plan.value).to be_nil
        expect(plan.errors).to include(include(code: :record_not_found))
      ensure
        s&.close
      end

      it "builds record_append operation plans without generating keys" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :draft,
          params: { attributes: { title: "Draft" } })
        plan = s.command_operation_plan(intent)

        expect(plan).to be_ready
        expect(plan.target).to eq(shape: :store, name: :commanded_reminders, key: nil)
        expect(plan.value).to eq(status: :open, title: "Draft")
        expect(plan.subject_key).to be_nil
      ensure
        s&.close
      end

      it "builds history_append operation plans with inferred target warnings" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :audit, params: { actor: "user-1" })
        plan = s.command_operation_plan(intent)

        expect(plan).to be_ready
        expect(plan.target).to eq(shape: :history, name: :commanded_reminders, key: nil)
        expect(plan.event).to eq(event: :audited, actor: "user-1")
        expect(plan.warnings).to include(include(code: :history_target_inferred))
      ensure
        s&.close
      end

      it "uses explicit history targets for history_append operation plans" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :audit,
          params: { actor: "user-1" },
          metadata: { history: :command_audits })
        plan = s.command_operation_plan(intent)

        expect(plan).to be_ready
        expect(plan.target).to eq(shape: :history, name: :command_audits, key: nil)
        expect(plan.warnings).to be_empty
      ensure
        s&.close
      end

      it "builds ready none operation plans with no mutation target" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :noop)
        plan = s.command_operation_plan(intent)

        expect(plan).to be_ready
        expect(plan.target).to eq(shape: :none)
        expect(plan.value).to be_nil
        expect(plan.event).to be_nil
        expect(plan.execution_allowed).to be false
      ensure
        s&.close
      end

      it "projects command intents into intended activity events" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          metadata: { request_id: "req-1" })
        event = s.command_activity_event(intent, metadata: { actor: "user-1" })

        expect(event).to be_frozen
        expect(event[:owner]).to eq(:commanded_reminders)
        expect(event.to_h).to include(
          schema_version: 1,
          kind: :command_activity_event,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          operation: :record_update,
          status: :intended,
          intent_status: :ready,
          plan_status: nil,
          target: nil,
          errors: [],
          warnings: [],
          metadata: { request_id: "req-1", actor: "user-1" },
          store_fact_exposed: false,
          value_hash_exposed: false,
          execution_allowed: false
        )
      ensure
        s&.close
      end

      it "projects ready command operation plans into planned activity events" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        plan = s.command_operation_plan(intent)
        event = s.command_activity_event(plan)

        expect(event.status).to eq(:planned)
        expect(event.plan_status).to eq(:ready)
        expect(event.target).to eq(shape: :store, name: :commanded_reminders, key: "r1")
        expect(event.errors).to eq([])
        expect(event.to_h).not_to have_key(:value)
        expect(event.to_h).not_to have_key(:fact_id)
        expect(event.to_h).not_to have_key(:value_hash)
      ensure
        s&.close
      end

      it "projects invalid command operation plans into rejected activity events" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete, key: "missing")
        plan = s.command_operation_plan(intent)
        event = s.command_activity_event(plan)

        expect(event.status).to eq(:rejected)
        expect(event.plan_status).to eq(:invalid)
        expect(event.errors).to include(include(code: :record_not_found))
        expect(event.execution_allowed).to be false
      ensure
        s&.close
      end

      it "allows explicit activity status overrides" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        event = s.command_activity_event(intent, status: :previewed)

        expect(event.status).to eq(:previewed)
      ensure
        s&.close
      end

      it "explicitly appends command activity and replays typed audit history by owner" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        plan = s.command_operation_plan(intent)
        event = s.command_activity_event(plan, metadata: { actor: "user-1" })
        receipt = s.append_command_activity(event)

        audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

        expect(receipt).to be_frozen
        expect(receipt[:history]).to eq(:command_activity)
        expect(receipt.to_h).to include(
          schema_version: 1,
          kind: :command_activity_receipt,
          status: :recorded,
          history: :command_activity,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          activity_status: :planned,
          store_fact_exposed: false,
          value_hash_exposed: false,
          execution_allowed: false
        )
        expect(receipt.to_h).not_to have_key(:fact_id)
        expect(receipt.to_h).not_to have_key(:value_hash)
        expect(receipt.to_h).not_to have_key(:causation)
        expect(audit.size).to eq(1)
        expect(audit.first).to be_a(Igniter::DurableModel::CommandActivity)
        expect(audit.first.owner).to eq(:commanded_reminders)
        expect(audit.first.command).to eq(:complete)
        expect(audit.first.metadata).to eq(actor: "user-1")
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "does not append command activity automatically during projection" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete, key: "missing")
        plan = s.command_operation_plan(intent)
        s.command_activity_event(plan)

        audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

        expect(audit).to be_empty
      ensure
        s&.close
      end

      it "does not append planned business histories when recording activity" do
        s = described_class.new
        s.register(CommandedReminder)
        s.register(TrackerLog)

        intent = s.command_intent(CommandedReminder, :audit,
          params: { actor: "user-1" },
          metadata: { history: :tracker_logs })
        plan = s.command_operation_plan(intent)
        event = s.command_activity_event(plan)

        s.append_command_activity(event)

        expect(s.replay(Igniter::DurableModel::CommandActivity,
          partition: :commanded_reminders).size).to eq(1)
        expect(s.replay(TrackerLog)).to be_empty
      ensure
        s&.close
      end

      it "applies ready record_update plans and records applied activity on request" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        plan = s.command_operation_plan(intent)
        receipt = s.apply_command(plan, audit: true)
        audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

        expect(receipt).to be_frozen
        expect(receipt[:status]).to eq(:applied)
        expect(receipt.to_h).to include(
          schema_version: 1,
          kind: :command_apply_receipt,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          operation: :record_update,
          target: { shape: :store, name: :commanded_reminders, key: "r1" },
          mutation_intent: :record_write,
          activity_recorded: true,
          store_fact_exposed: false,
          value_hash_exposed: false,
          execution_boundary: :app,
          errors: [],
          warnings: []
        )
        expect(receipt.to_h).not_to have_key(:fact_id)
        expect(receipt.to_h).not_to have_key(:value_hash)
        expect(receipt.to_h).not_to have_key(:causation)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
        expect(audit.size).to eq(1)
        expect(audit.first.status).to eq(:applied)
      ensure
        s&.close
      end

      it "applies ready record_append plans only when an explicit key is available" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :draft,
          params: { attributes: { id: "r2", title: "Draft" } })
        plan = s.command_operation_plan(intent)
        rejected = s.apply_command(plan)

        expect(rejected.status).to eq(:rejected)
        expect(rejected.errors).to include(include(code: :missing_key))
        expect(rejected.activity_recorded).to be false
        expect(s.read(CommandedReminder, key: "r2")).to be_nil
        applied = s.apply_command(plan, key: "r2")
        expect(applied.to_h).to include(
          status: :applied,
          operation: :record_append,
          target: { shape: :store, name: :commanded_reminders, key: "r2" },
          mutation_intent: :record_write,
          activity_recorded: false
        )
        expect(s.read(CommandedReminder, key: "r2").status).to eq(:open)
      ensure
        s&.close
      end

      it "applies history_append plans through resolved or explicit History classes" do
        s = described_class.new
        s.register(CommandedReminder)
        s.register(TrackerLog)

        resolved_intent = s.command_intent(CommandedReminder, :audit,
          params: { tracker_id: "sleep", value: 8.5 },
          metadata: { history: :tracker_logs })
        resolved_plan = s.command_operation_plan(resolved_intent)
        resolved_receipt = s.apply_command(resolved_plan)

        explicit_intent = s.command_intent(CommandedReminder, :audit,
          params: { tracker_id: "focus", value: 3.0 },
          metadata: { history: :tracker_logs })
        explicit_plan = s.command_operation_plan(explicit_intent)
        explicit_receipt = s.apply_command(explicit_plan, history_class: TrackerLog)

        expect(resolved_receipt.to_h).to include(
          status: :applied,
          operation: :history_append,
          mutation_intent: :history_append
        )
        expect(explicit_receipt.status).to eq(:applied)
        expect(s.replay(TrackerLog, partition: "sleep").map(&:value)).to eq([8.5])
        expect(s.replay(TrackerLog, partition: "focus").map(&:value)).to eq([3.0])
      ensure
        s&.close
      end

      it "applies none plans as app-boundary no-ops without storage mutation" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :noop)
        plan = s.command_operation_plan(intent)
        receipt = s.apply_command(plan, audit: true)
        audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

        expect(receipt.to_h).to include(
          status: :applied,
          operation: :none,
          target: { shape: :none },
          mutation_intent: :none,
          activity_recorded: true
        )
        expect(audit.size).to eq(1)
        expect(audit.first.status).to eq(:applied)
      ensure
        s&.close
      end

      it "rejects invalid plans without mutation and can audit the rejection" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete, key: "missing")
        plan = s.command_operation_plan(intent)
        receipt = s.apply_command(plan, audit: true)
        audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

        expect(receipt.to_h).to include(
          status: :rejected,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "missing",
          operation: :record_update,
          mutation_intent: :none,
          activity_recorded: true
        )
        expect(receipt.errors).to include(include(code: :record_not_found))
        expect(s.read(CommandedReminder, key: "missing")).to be_nil
        expect(audit.size).to eq(1)
        expect(audit.first.status).to eq(:rejected)
        expect(audit.first.errors).to include(include(code: :record_not_found))
      ensure
        s&.close
      end

      it "builds app-safe command policy decisions without mutation" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        plan = s.command_operation_plan(intent)
        decision = s.command_policy_decision(plan,
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-1" })

        expect(decision).to be_frozen
        expect(decision).to be_allowed
        expect(decision[:status]).to eq(:allowed)
        expect(decision.to_h).to include(
          schema_version: 1,
          kind: :command_policy_decision,
          status: :allowed,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          operation: :record_update,
          actor: "user-1",
          required_capabilities: [:reminder_complete],
          granted_capabilities: [:reminder_complete],
          missing_capabilities: [],
          review_required: false,
          errors: [],
          warnings: [],
          metadata: { request_id: "req-1" },
          execution_boundary: :app
        )
        expect(decision.to_h).not_to have_key(:fact_id)
        expect(decision.to_h).not_to have_key(:value_hash)
        expect(decision.to_h).not_to have_key(:causation)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "denies missing capabilities and apply refuses without mutation" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        plan = s.command_operation_plan(intent)
        decision = s.command_policy_decision(plan, actor: "user-1", capabilities: [])
        receipt = s.apply_command(plan, policy_decision: decision, audit: true)
        audit = s.replay(Igniter::DurableModel::CommandActivity, partition: :commanded_reminders)

        expect(decision).to be_denied
        expect(decision.missing_capabilities).to eq([:reminder_complete])
        expect(receipt.to_h).to include(
          status: :rejected,
          mutation_intent: :none,
          activity_recorded: true
        )
        expect(receipt.errors).to include(include(code: :missing_capabilities))
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
        expect(audit.first.status).to eq(:rejected)
        expect(audit.first.errors).to include(include(code: :missing_capabilities))
      ensure
        s&.close
      end

      it "requires review approval when command policy asks for review" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :review_complete, key: "r1")
        plan = s.command_operation_plan(intent)
        pending = s.command_policy_decision(plan,
          actor: "user-1",
          capabilities: [:reminder_complete])
        approved = s.command_policy_decision(plan,
          actor: "user-1",
          capabilities: [:reminder_complete],
          approvals: [{ command: :review_complete, subject_key: "r1", actor: "manager-1" }])

        expect(pending).to be_review_required
        expect(pending.warnings).to include(include(code: :review_required))
        expect(approved).to be_allowed
        expect(s.apply_command(plan, policy_decision: pending).status).to eq(:rejected)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
        expect(s.apply_command(plan, policy_decision: approved).status).to eq(:applied)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
      ensure
        s&.close
      end

      it "can require an implicit policy decision during apply" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete, key: "r1")
        plan = s.command_operation_plan(intent)
        receipt = s.apply_command(plan, require_policy: true)

        expect(receipt.status).to eq(:rejected)
        expect(receipt.errors).to include(include(code: :missing_capabilities))
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "returns unknown command lifecycle when no activity matches" do
        s = described_class.new

        lifecycle = s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "missing",
          request_id: "req-missing"
        )

        expect(lifecycle).to be_frozen
        expect(lifecycle.status).to eq(:unknown)
        expect(lifecycle.to_h).to include(
          schema_version: 1,
          kind: :command_lifecycle,
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "missing",
          request_id: "req-missing",
          activity_statuses: [],
          errors: [],
          warnings: [],
          execution_boundary: :app,
          store_fact_exposed: false,
          value_hash_exposed: false
        )
        expect(lifecycle.latest_activity).to be_nil
      ensure
        s&.close
      end

      it "folds planned command lifecycle from explicit activity history" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          metadata: { request_id: "req-1" })
        plan = s.command_operation_plan(intent)
        s.append_command_activity(s.command_activity_event(plan))
        lifecycle = s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-1"
        )

        expect(lifecycle.status).to eq(:planned)
        expect(lifecycle.activity_statuses).to eq([:planned])
        expect(lifecycle.plan_status).to eq(:ready)
        expect(lifecycle.latest_activity).not_to have_key(:fact_id)
        expect(lifecycle.latest_activity).not_to have_key(:value_hash)
      ensure
        s&.close
      end

      it "folds policy denied lifecycle and aggregates policy errors" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          metadata: { request_id: "req-denied" })
        plan = s.command_operation_plan(intent)
        decision = s.command_policy_decision(plan, actor: "user-1", capabilities: [])
        s.apply_command(plan, policy_decision: decision, audit: true)
        lifecycle = s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-denied"
        )

        expect(lifecycle.status).to eq(:policy_denied)
        expect(lifecycle).to be_rejected
        expect(lifecycle.policy_status).to eq(:denied)
        expect(lifecycle.apply_status).to eq(:rejected)
        expect(lifecycle.errors).to include(include(code: :missing_capabilities))
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "folds review required lifecycle from rejected apply activity" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :review_complete,
          key: "r1",
          metadata: { request_id: "req-review" })
        plan = s.command_operation_plan(intent)
        decision = s.command_policy_decision(plan,
          actor: "user-1",
          capabilities: [:reminder_complete])
        s.apply_command(plan, policy_decision: decision, audit: true)
        lifecycle = s.command_lifecycle(
          owner: :commanded_reminders,
          command: :review_complete,
          subject_key: "r1",
          request_id: "req-review"
        )

        expect(lifecycle.status).to eq(:review_required)
        expect(lifecycle).to be_review_required
        expect(lifecycle.policy_status).to eq(:review_required)
        expect(lifecycle.warnings).to include(include(code: :review_required))
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "folds generic rejected lifecycle from invalid command activity" do
        s = described_class.new
        s.register(CommandedReminder)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "missing",
          metadata: { request_id: "req-invalid" })
        plan = s.command_operation_plan(intent)
        s.apply_command(plan, audit: true)
        lifecycle = s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "missing",
          request_id: "req-invalid"
        )

        expect(lifecycle.status).to eq(:rejected)
        expect(lifecycle.errors).to include(include(code: :record_not_found))
      ensure
        s&.close
      end

      it "folds applied lifecycle and exposes a filtered typed timeline" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          metadata: { request_id: "req-apply" })
        plan = s.command_operation_plan(intent)
        policy = s.command_policy_decision(plan,
          actor: "user-1",
          capabilities: [:reminder_complete])
        s.append_command_activity(s.command_activity_event(plan))
        s.apply_command(plan, policy_decision: policy, audit: true)
        lifecycle = s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-apply"
        )
        timeline = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-apply"
        )

        expect(lifecycle.status).to eq(:applied)
        expect(lifecycle.activity_statuses).to eq(%i[planned applied])
        expect(lifecycle.actor).to eq("user-1")
        expect(lifecycle.latest_activity).to include(status: :applied)
        expect(timeline.map(&:status)).to eq(%i[planned applied])
        expect(timeline).to all(be_a(Igniter::DurableModel::CommandActivity))
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
      ensure
        s&.close
      end

      it "runs command flow preview without mutation and preserves request identity" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        flow = s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-flow-preview" })

        expect(flow).to be_frozen
        expect(flow).to be_a(Igniter::DurableModel::CommandFlow)
        expect(flow.status).to eq(:planned)
        expect(flow.mode).to eq(:preview)
        expect(flow.applied?).to be false
        expect(flow.request_id).to eq("req-flow-preview")
        expect(flow.intent.metadata[:request_id]).to eq("req-flow-preview")
        expect(flow.plan).to be_ready
        expect(flow.policy_decision).to be_allowed
        expect(flow.apply_receipt).to be_nil
        expect(flow.lifecycle).to be_a(Igniter::DurableModel::CommandLifecycle)
        expect(flow.lifecycle.status).to eq(:planned)
        expect(flow.to_h[:plan]).not_to have_key(:value)
        expect(flow.to_h).not_to have_key(:fact_id)
        expect(flow.to_h).not_to have_key(:causation)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "generates command flow request ids when metadata omits one" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        flow = s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete])

        expect(flow.request_id).to match(/\Acmd_[0-9a-f]{12}\z/)
        expect(flow.metadata[:request_id]).to eq(flow.request_id)
        expect(flow.lifecycle.request_id).to eq(flow.request_id)
      ensure
        s&.close
      end

      it "applies command flow only in explicit apply mode" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        flow = s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-flow-apply" },
          mode: :apply,
          audit: true)
        audit = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-flow-apply")

        expect(flow.status).to eq(:applied)
        expect(flow).to be_applied
        expect(flow.apply_receipt.status).to eq(:applied)
        expect(flow.apply_receipt.activity_recorded).to be true
        expect(flow.lifecycle.status).to eq(:applied)
        expect(flow.lifecycle.apply_status).to eq(:applied)
        expect(audit.map(&:status)).to eq([:applied])
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:done)
      ensure
        s&.close
      end

      it "returns policy denied command flow without mutation" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        flow = s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [],
          metadata: { request_id: "req-flow-denied" },
          mode: :apply,
          audit: true)

        expect(flow.status).to eq(:policy_denied)
        expect(flow).to be_rejected
        expect(flow.apply_receipt.status).to eq(:rejected)
        expect(flow.errors).to include(include(code: :missing_capabilities))
        expect(flow.lifecycle.status).to eq(:policy_denied)
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "returns review required command flow without mutation" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        flow = s.command_flow(CommandedReminder, :review_complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-flow-review" },
          mode: :apply,
          audit: true)

        expect(flow.status).to eq(:review_required)
        expect(flow).to be_review_required
        expect(flow.apply_receipt.status).to eq(:rejected)
        expect(flow.lifecycle.status).to eq(:review_required)
        expect(flow.warnings).to include(include(code: :review_required))
        expect(s.read(CommandedReminder, key: "r1").status).to eq(:open)
      ensure
        s&.close
      end

      it "returns rejected command flow for invalid plans without mutation" do
        s = described_class.new
        s.register(CommandedReminder)

        flow = s.command_flow(CommandedReminder, :complete,
          key: "missing",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-flow-invalid" },
          mode: :apply,
          audit: true)

        expect(flow.status).to eq(:rejected)
        expect(flow.apply_receipt.status).to eq(:rejected)
        expect(flow.errors).to include(include(code: :record_not_found))
        expect(flow.lifecycle.status).to eq(:rejected)
        expect(s.read(CommandedReminder, key: "missing")).to be_nil
      ensure
        s&.close
      end

      it "records preview activity only when command flow audit is requested" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-flow-no-audit" })
        audited = s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-flow-audit" },
          audit: true)

        expect(s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-flow-no-audit").status).to eq(:unknown)
        expect(audited.lifecycle.status).to eq(:planned)
        expect(s.command_lifecycle(
          owner: :commanded_reminders,
          command: :complete,
          subject_key: "r1",
          request_id: "req-flow-audit").status).to eq(:planned)
      ensure
        s&.close
      end

      it "rejects unknown command flow modes" do
        s = described_class.new
        s.register(CommandedReminder)

        expect do
          s.command_flow(CommandedReminder, :complete, mode: :surprise)
        end.to raise_error(ArgumentError, /Unknown command_flow mode/)
      ensure
        s&.close
      end

      it "builds app-safe temporal command flow slices with counts" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-slice-planned" },
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-slice-applied" },
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "r2",
          actor: "user-2",
          capabilities: [],
          metadata: { request_id: "req-slice-denied" },
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :review_complete,
          key: "r2",
          actor: "user-3",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-slice-review" },
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "missing",
          actor: "user-4",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-slice-invalid" },
          mode: :apply,
          audit: true)

        slice = s.command_flow_slice(owner: :commanded_reminders)

        expect(slice).to be_frozen
        expect(slice[:kind]).to eq(:command_flow_slice)
        expect(slice.size).to eq(5)
        expect(slice.empty?).to be false
        expect(slice.status_counts).to include(
          planned: 1,
          applied: 1,
          policy_denied: 1,
          review_required: 1,
          rejected: 1
        )
        expect(slice.command_counts).to include(complete: 4, review_complete: 1)
        expect(slice.actor_counts).to include("user-1" => 2, "user-2" => 1)
        expect(slice.subject_count).to eq(3)
        expect(slice.request_count).to eq(5)
        expect(slice.summary).to include(total: 5, empty: false)
        expect(slice.items.first).to include(
          owner: :commanded_reminders,
          request_id: "req-slice-planned",
          status: :planned,
          activity_count: 1
        )
        expect(slice.to_h).not_to have_key(:fact_id)
        expect(slice.items.first).not_to have_key(:fact_id)
        expect(slice.items.first).not_to have_key(:value)
        expect(slice.items.first).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "filters command flow slices by command subject request actor status and limit" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-filter-1" },
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "r2",
          actor: "user-2",
          capabilities: [],
          metadata: { request_id: "req-filter-2" },
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :review_complete,
          key: "r2",
          actor: "user-3",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-filter-3" },
          mode: :apply,
          audit: true)

        expect(s.command_flow_slice(
          owner: :commanded_reminders,
          command: :complete).size).to eq(2)
        expect(s.command_flow_slice(
          owner: :commanded_reminders,
          subject_key: "r2").size).to eq(2)
        expect(s.command_flow_slice(
          owner: :commanded_reminders,
          request_id: "req-filter-1").items.map { |item| item[:request_id] }).to eq(["req-filter-1"])
        expect(s.command_flow_slice(
          owner: :commanded_reminders,
          actor: "user-2").items.map { |item| item[:actor] }).to eq(["user-2"])
        expect(s.command_flow_slice(
          owner: :commanded_reminders,
          status: :policy_denied).items.map { |item| item[:status] }).to eq([:policy_denied])
        expect(s.command_flow_slice(
          owner: :commanded_reminders,
          limit: 2).size).to eq(2)
        expect(s.command_flow_summary(owner: :commanded_reminders)[:total]).to eq(3)
      ensure
        s&.close
      end

      it "applies temporal filters to command flow slices" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)
        s.write(CommandedReminder, key: "r3", id: "r3", title: "Read", status: :open)

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-window-before" },
          audit: true)
        sleep 0.01
        since = Time.at(Time.now.to_f)
        sleep 0.01
        s.command_flow(CommandedReminder, :complete,
          key: "r2",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-window-inside" },
          audit: true)
        sleep 0.01
        as_of = Time.at(Time.now.to_f)
        sleep 0.01
        s.command_flow(CommandedReminder, :complete,
          key: "r3",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-window-after" },
          audit: true)

        slice = s.command_flow_slice(
          owner: :commanded_reminders,
          since: since,
          as_of: as_of)

        expect(slice.items.map { |item| item[:request_id] }).to eq(["req-window-inside"])
        expect(slice.since).to eq(since)
        expect(slice.as_of).to eq(as_of)
        expect(slice.generated_at).to be_a(Time)
      ensure
        s&.close
      end

      it "groups command flow slice activity by request id" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        intent = s.command_intent(CommandedReminder, :complete,
          key: "r1",
          metadata: { request_id: "req-grouped" })
        plan = s.command_operation_plan(intent)
        policy = s.command_policy_decision(plan, capabilities: [:reminder_complete])
        s.append_command_activity(s.command_activity_event(plan))
        s.apply_command(plan, policy_decision: policy, audit: true)

        slice = s.command_flow_slice(
          owner: :commanded_reminders,
          request_id: "req-grouped")

        expect(slice.size).to eq(1)
        expect(slice.items.first).to include(
          request_id: "req-grouped",
          status: :applied,
          activity_count: 2
        )
        expect(slice.items.first[:errors]).to eq([])
        expect(slice.items.first[:warnings]).to eq([])
      ensure
        s&.close
      end

      it "returns ok command flow monitor results when rules are empty" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-monitor-empty" },
          audit: true)
        result = s.command_flow_monitor(owner: :commanded_reminders, name: :daily)

        expect(result).to be_frozen
        expect(result).to be_a(Igniter::DurableModel::CommandFlowMonitorResult)
        expect(result).to be_ok
        expect(result).not_to be_triggered
        expect(result[:name]).to eq(:daily)
        expect(result.rules).to eq([])
        expect(result.observations).to eq([])
        expect(result.alerts).to eq([])
        expect(result.summary).to include(total: 1)
        expect(result.to_h).not_to have_key(:fact_id)
        expect(result.to_h).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "evaluates all command flow monitor metrics" do
        s = described_class.new
        slice = Igniter::DurableModel::CommandFlowSlice.new(
          owner: :commanded_reminders,
          filters: {},
          items: [
            {
              owner: :commanded_reminders,
              command: :complete,
              actor: "user-1",
              subject_key: "r1",
              request_id: "req-1",
              status: :applied
            },
            {
              owner: :commanded_reminders,
              command: :complete,
              actor: "user-1",
              subject_key: "r2",
              request_id: "req-2",
              status: :policy_denied
            },
            {
              owner: :commanded_reminders,
              command: :review_complete,
              actor: "user-2",
              subject_key: "r2",
              request_id: "req-3",
              status: :review_required
            }
          ])

        result = s.command_flow_monitor(
          owner: :commanded_reminders,
          slice: slice,
          rules: [
            { name: :total, metric: :total, op: :==, value: 3, severity: :info },
            { name: :status_count, metric: :status_count, status: :policy_denied, op: :==, value: 1, severity: :info },
            { name: :status_ratio, metric: :status_ratio, status: :policy_denied, op: :>, value: 0.3, severity: :info },
            { name: :command_count, metric: :command_count, command: :complete, op: :==, value: 2, severity: :info },
            { name: :actor_count, metric: :actor_count, actor: "user-1", op: :==, value: 2, severity: :info },
            { name: :subject_count, metric: :subject_count, op: :==, value: 2, severity: :info },
            { name: :request_count, metric: :request_count, op: :==, value: 3, severity: :info }
          ])

        expect(result).to be_ok
        expect(result).to be_triggered
        expect(result.alerts.map { |alert| alert[:name] }).to eq(
          %i[total status_count status_ratio command_count actor_count subject_count request_count]
        )
        expect(result.observations.map { |entry| entry[:matched] }).to all(be true)
      ensure
        s&.close
      end

      it "supports all command flow monitor operators" do
        s = described_class.new
        slice = Igniter::DurableModel::CommandFlowSlice.new(
          owner: :commanded_reminders,
          filters: {},
          items: [
            { command: :complete, status: :applied },
            { command: :complete, status: :applied }
          ])

        result = s.command_flow_monitor(
          owner: :commanded_reminders,
          slice: slice,
          rules: [
            { name: :gt, metric: :total, op: :>, value: 1, severity: :info },
            { name: :gte, metric: :total, op: :>=, value: 2, severity: :info },
            { name: :lt, metric: :total, op: :<, value: 3, severity: :info },
            { name: :lte, metric: :total, op: :<=, value: 2, severity: :info },
            { name: :eq, metric: :total, op: :==, value: 2, severity: :info },
            { name: :neq, metric: :total, op: :!=, value: 3, severity: :info }
          ])

        expect(result.status).to eq(:ok)
        expect(result.alerts.map { |alert| alert[:name] }).to eq(%i[gt gte lt lte eq neq])
      ensure
        s&.close
      end

      it "folds command flow monitor severity to warning and critical" do
        s = described_class.new
        slice = Igniter::DurableModel::CommandFlowSlice.new(
          owner: :commanded_reminders,
          filters: {},
          items: [
            { command: :complete, status: :policy_denied },
            { command: :complete, status: :review_required }
          ])
        warning = s.command_flow_monitor(
          owner: :commanded_reminders,
          slice: slice,
          rules: [{
            name: :denial_rate,
            metric: :status_ratio,
            status: :policy_denied,
            op: :>=,
            value: 0.5,
            severity: :warning
          }])
        critical = s.command_flow_monitor(
          owner: :commanded_reminders,
          slice: slice,
          rules: [
            {
              name: :denial_rate,
              metric: :status_ratio,
              status: :policy_denied,
              op: :>=,
              value: 0.5,
              severity: :warning
            },
            {
              name: :review_backlog,
              metric: :status_count,
              status: :review_required,
              op: :>=,
              value: 1,
              severity: :critical
            }
          ])

        expect(warning).to be_warning
        expect(critical).to be_critical
      ensure
        s&.close
      end

      it "raises clear errors for invalid command flow monitor rules" do
        s = described_class.new

        expect do
          s.command_flow_monitor(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :mystery, op: :>, value: 1 }])
        end.to raise_error(ArgumentError, /metric/)
        expect do
          s.command_flow_monitor(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :total, op: :between, value: 1 }])
        end.to raise_error(ArgumentError, /operator/)
        expect do
          s.command_flow_monitor(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :total, op: :>, value: 1, severity: :panic }])
        end.to raise_error(ArgumentError, /severity/)
        expect do
          s.command_flow_monitor(owner: :commanded_reminders,
            rules: [{ name: :missing_status, metric: :status_count, op: :>, value: 1 }])
        end.to raise_error(ArgumentError, /requires status/)
      ensure
        s&.close
      end

      it "uses provided command flow monitor slices without replaying history" do
        s = described_class.new
        slice = Igniter::DurableModel::CommandFlowSlice.new(
          owner: :provided,
          filters: { status: :applied },
          items: [{ command: :complete, status: :applied, actor: "user-1" }])

        result = s.command_flow_monitor(
          owner: :commanded_reminders,
          slice: slice,
          rules: [{
            name: :provided_total,
            metric: :total,
            op: :==,
            value: 1,
            severity: :warning
          }]
        )

        expect(result.owner).to eq(:commanded_reminders)
        expect(result.slice[:owner]).to eq(:provided)
        expect(result).to be_warning
        expect(result.alerts.first[:actual]).to eq(1)
      ensure
        s&.close
      end

      it "evaluates command flow monitors over embedded command history" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          metadata: { request_id: "req-monitor-applied" },
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "r2",
          actor: "user-2",
          capabilities: [],
          metadata: { request_id: "req-monitor-denied" },
          mode: :apply,
          audit: true)

        result = s.command_flow_monitor(
          owner: :commanded_reminders,
          command: :complete,
          rules: [
            {
              name: :denials,
              metric: :status_count,
              status: :policy_denied,
              op: :>=,
              value: 1,
              severity: :warning,
              message: "policy denials observed",
              metadata: { dashboard: :ops }
            },
            {
              name: :too_many,
              metric: :total,
              op: :>,
              value: 5,
              severity: :critical
            }
          ])

        expect(result).to be_warning
        expect(result.summary[:total]).to eq(2)
        expect(result.observations.size).to eq(2)
        expect(result.alerts.size).to eq(1)
        expect(result.alerts.first).to include(
          name: :denials,
          metric: :status_count,
          expected: 1,
          actual: 1,
          matched: true,
          severity: :warning,
          message: "policy denials observed",
          metadata: { dashboard: :ops }
        )
        expect(result.to_h).not_to have_key(:fact_id)
        expect(result.to_h).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "registers command flow view descriptors and exposes snapshots" do
        s = described_class.new

        descriptor = s.register_command_flow_view(:assignment_health,
          owner: :commanded_reminders,
          command: :complete,
          actor: "user-1",
          horizon: { mode: :live, as_of: :latest },
          action_policy: {
            inspect: true,
            mutate: :requires_pinned_horizon,
            required_capabilities: [:dispatch_review]
          },
          rules: [{
            name: :denials,
            metric: :status_count,
            status: :policy_denied,
            op: :>,
            value: 0
          }],
          metadata: { dashboard: :dispatch })

        expect(descriptor).to be_frozen
        expect(descriptor).to be_live
        expect(descriptor).not_to be_reproducible
        expect(descriptor.to_h).to include(
          kind: :command_flow_view_descriptor,
          name: :assignment_health,
          owner: :commanded_reminders,
          filters: { command: :complete, actor: "user-1" },
          mode: :live,
          metadata: { dashboard: :dispatch },
          store_fact_exposed: false,
          value_hash_exposed: false
        )
        expect(s._command_flow_views[:assignment_health]).to include(
          name: :assignment_health,
          owner: :commanded_reminders
        )
      ensure
        s&.close
      end

      it "overwrites duplicate command flow view registrations" do
        s = described_class.new

        s.register_command_flow_view(:health, owner: :commanded_reminders, command: :complete)
        s.register_command_flow_view(:health, owner: :commanded_reminders, command: :review_complete)

        expect(s._command_flow_views[:health][:filters]).to eq(command: :review_complete)
      ensure
        s&.close
      end

      it "raises for unknown command flow views and horizon modes" do
        s = described_class.new

        expect { s.command_flow_view(:missing) }
          .to raise_error(ArgumentError, /Unknown command flow view/)
        expect do
          s.register_command_flow_view(:bad,
            owner: :commanded_reminders,
            horizon: { mode: :timey_wimey })
        end.to raise_error(ArgumentError, /horizon mode/)
      ensure
        s&.close
      end

      it "evaluates embedded command flow operational views over real history" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)
        s.register_command_flow_view(:assignment_health,
          owner: :commanded_reminders,
          command: :complete,
          horizon: {
            mode: :live,
            as_of: :latest,
            rule_version: :latest,
            fact_scope: { history: :command_activity, owner: :commanded_reminders }
          },
          action_policy: {
            inspect: true,
            suggest: true,
            mutate: :requires_pinned_horizon,
            execute: :forbidden,
            required_capabilities: [:dispatch_review]
          },
          rules: [{
            name: :denials,
            metric: :status_count,
            status: :policy_denied,
            op: :>=,
            value: 1,
            severity: :warning
          }])

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "r2",
          capabilities: [],
          mode: :apply,
          audit: true)
        view = s.command_flow_view(:assignment_health)

        expect(view).to be_frozen
        expect(view).to be_warning
        expect(view).to be_live
        expect(view).not_to be_reproducible
        expect(view).to be_pin_required
        expect(view.slice.size).to eq(2)
        expect(view.monitor).to be_warning
        expect(view.summary[:total]).to eq(2)
        expect(view.actionable?(:inspect, capabilities: [:dispatch_review])).to be true
        expect(view.actionable?(:suggest, capabilities: [])).to be false
        expect(view.actionable?(:mutate, capabilities: [:dispatch_review])).to be false
        expect(view.actionable?(:execute, capabilities: [:dispatch_review])).to be false
        expect(view.to_h).not_to have_key(:fact_id)
        expect(view.to_h).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "supports reproducible command flow views and pinned actions" do
        s = described_class.new
        fixed_as_of = Time.utc(2026, 1, 31)
        s.register_command_flow_view(:repro_health,
          owner: :commanded_reminders,
          horizon: {
            as_of: fixed_as_of,
            rule_version: :rules_v1,
            fact_scope: { history: :command_activity, owner: :commanded_reminders }
          },
          action_policy: {
            approve: :requires_pinned_horizon,
            mutate: :requires_capability,
            required_capabilities: [:dispatch_review]
          })

        descriptor = s._command_flow_views[:repro_health]
        view = s.command_flow_view(:repro_health)

        expect(descriptor[:mode]).to eq(:reproducible)
        expect(view).to be_reproducible
        expect(view).not_to be_pin_required
        expect(view.actionable?(:approve, capabilities: [:dispatch_review])).to be true
        expect(view.actionable?(:approve, capabilities: [])).to be false
        expect(view.actionable?(:mutate, capabilities: [:dispatch_review])).to be true
      ensure
        s&.close
      end

      it "merges command flow view descriptor filters with call-time overrides" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.write(CommandedReminder, key: "r2", id: "r2", title: "Pay bills", status: :open)
        s.register_command_flow_view(:by_actor,
          owner: :commanded_reminders,
          command: :complete,
          actor: "user-1")

        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          actor: "user-1",
          capabilities: [:reminder_complete],
          mode: :apply,
          audit: true)
        s.command_flow(CommandedReminder, :complete,
          key: "r2",
          actor: "user-2",
          capabilities: [:reminder_complete],
          mode: :apply,
          audit: true)

        default_view = s.command_flow_view(:by_actor)
        override_view = s.command_flow_view(:by_actor, overrides: { actor: "user-2" })

        expect(default_view.slice.size).to eq(1)
        expect(default_view.filters).to include(actor: "user-1")
        expect(override_view.slice.size).to eq(1)
        expect(override_view.filters).to include(actor: "user-2")
      ensure
        s&.close
      end

      it "pins live command flow views into reproducible evidence" do
        s = described_class.new
        fixed_as_of = Time.utc(2026, 12, 1, 12, 0, 0)
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.register_command_flow_view(:assignment_pin_health,
          owner: :commanded_reminders,
          command: :complete,
          horizon: { mode: :live, as_of: :latest },
          action_policy: {
            mutate: :requires_pinned_horizon,
            required_capabilities: [:dispatch_review]
          },
          rules: [{
            name: :denials,
            metric: :status_count,
            status: :policy_denied,
            op: :>=,
            value: 1,
            severity: :warning
          }])
        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [],
          mode: :apply,
          audit: true)
        before_events = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size

        pin = s.pin_command_flow_view(:assignment_pin_health,
          action: :mutate,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review],
          as_of: fixed_as_of,
          metadata: { request_id: "pin-1" })
        after_events = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size

        expect(pin).to be_frozen
        expect(pin).to be_pinned
        expect(pin).to be_reproducible
        expect(pin[:status]).to eq(:pinned)
        expect(pin.name).to eq(:assignment_pin_health)
        expect(pin.action).to eq(:mutate)
        expect(pin.actor).to eq("dispatcher-1")
        expect(pin.missing_capabilities).to eq([])
        expect(pin.horizon).to include(
          mode: :reproducible,
          as_of: fixed_as_of,
          rule_version: :current_rules,
          fact_scope: { history: :command_activity, owner: :commanded_reminders }
        )
        expect(pin.view).to be_reproducible
        expect(pin.view).to be_warning
        expect(pin.view.summary[:total]).to eq(1)
        expect(pin.receipt).to include(
          kind: :command_flow_view_pin_receipt,
          view_name: :assignment_pin_health,
          owner: :commanded_reminders,
          action: :mutate,
          actor: "dispatcher-1",
          status: :pinned,
          meaning_status: :reproducible,
          view_status: :warning,
          monitor_status: :warning,
          metadata: { request_id: "pin-1" }
        )
        expect(pin.receipt[:receipt_id]).to start_with("cfvp_")
        expect(pin.to_h).not_to have_key(:fact_id)
        expect(pin.to_h).not_to have_key(:value_hash)
        expect(pin.to_h).not_to have_key(:causation)
        expect(after_events).to eq(before_events)
      ensure
        s&.close
      end

      it "blocks forbidden command flow view pin actions" do
        s = described_class.new
        s.register_command_flow_view(:blocked_health,
          owner: :commanded_reminders,
          action_policy: { execute: :forbidden })

        pin = s.pin_command_flow_view(:blocked_health, action: :execute)

        expect(pin).to be_blocked
        expect(pin).not_to be_reproducible
        expect(pin.errors.map { |error| error[:code] }).to include(:action_forbidden)
        expect(pin.receipt[:status]).to eq(:blocked)
        expect(pin.view).to be_reproducible
      ensure
        s&.close
      end

      it "blocks command flow view pins with missing capabilities" do
        s = described_class.new
        s.register_command_flow_view(:capability_health,
          owner: :commanded_reminders,
          action_policy: {
            approve: :requires_pinned_horizon,
            required_capabilities: %i[dispatch_review ops_lead]
          })

        pin = s.pin_command_flow_view(:capability_health,
          action: :approve,
          capabilities: [:dispatch_review])

        expect(pin).to be_blocked
        expect(pin.missing_capabilities).to eq([:ops_lead])
        expect(pin.errors.map { |error| error[:code] }).to include(:missing_capabilities)
        expect(pin.receipt[:missing_capabilities]).to eq([:ops_lead])
      ensure
        s&.close
      end

      it "blocks unknown command flow view pin actions without raising" do
        s = described_class.new
        s.register_command_flow_view(:action_health, owner: :commanded_reminders)

        pin = s.pin_command_flow_view(:action_health, action: :teleport)

        expect(pin).to be_blocked
        expect(pin.errors.map { |error| error[:code] }).to include(:unknown_view_action)
      ensure
        s&.close
      end

      it "raises for missing command flow view pins and malformed actions" do
        s = described_class.new

        expect { s.pin_command_flow_view(:missing, action: :mutate) }
          .to raise_error(ArgumentError, /Unknown command flow view/)
        expect { s.pin_command_flow_view(:missing, action: nil) }
          .to raise_error(ArgumentError, /action: is required/)
      ensure
        s&.close
      end

      it "appends pinned command flow decisions explicitly" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.register_command_flow_view(:decision_health,
          owner: :commanded_reminders,
          command: :complete,
          action_policy: {
            mutate: :requires_pinned_horizon,
            required_capabilities: [:dispatch_review]
          },
          rules: [{
            name: :denials,
            metric: :status_count,
            status: :policy_denied,
            op: :>=,
            value: 1,
            severity: :warning
          }])
        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [],
          mode: :apply,
          audit: true)
        before_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        pin = s.pin_command_flow_view(:decision_health,
          action: :mutate,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review],
          metadata: { request_id: "pin-decision", source: :pin })

        expect(s.command_flow_decisions(owner: :commanded_reminders)).to eq([])
        receipt = s.append_command_flow_decision(pin,
          metadata: { source: :append, reviewer: "lead-1" })
        after_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        record = s.read(CommandedReminder, key: "r1")
        decisions = s.command_flow_decisions(
          owner: :commanded_reminders,
          view_name: :decision_health,
          action: :mutate,
          actor: "dispatcher-1",
          status: :pinned,
          meaning_status: :reproducible,
          receipt_id: pin.receipt[:receipt_id],
          decision_receipt_id: receipt.decision_receipt_id
        )

        expect(receipt).to be_frozen
        expect(receipt).to be_appended
        expect(receipt[:kind]).to eq(:command_flow_decision_receipt)
        expect(receipt.receipt_id).to eq(pin.receipt[:receipt_id])
        expect(receipt.decision_receipt_id).to start_with("cfd_")
        expect(receipt.to_h).not_to have_key(:fact_id)
        expect(receipt.to_h).not_to have_key(:value_hash)
        expect(receipt.to_h).not_to have_key(:causation)
        expect(decisions.size).to eq(1)
        expect(decisions.first).to be_a(Igniter::DurableModel::CommandFlowDecision)
        expect(decisions.first.to_h).to include(
          owner: :commanded_reminders,
          view_name: :decision_health,
          action: :mutate,
          actor: "dispatcher-1",
          status: :pinned,
          meaning_status: :reproducible,
          receipt_id: pin.receipt[:receipt_id],
          decision_receipt_id: receipt.decision_receipt_id,
          view_status: :warning,
          monitor_status: :warning,
          store_fact_exposed: false,
          value_hash_exposed: false
        )
        expect(decisions.first.metadata).to include(
          request_id: "pin-decision",
          source: :append,
          reviewer: "lead-1"
        )
        expect(decisions.first.summary[:total]).to eq(1)
        expect(record.status).to eq(:open)
        expect(after_activity).to eq(before_activity)
      ensure
        s&.close
      end

      it "appends blocked command flow decisions" do
        s = described_class.new
        s.register_command_flow_view(:blocked_decision_health,
          owner: :commanded_reminders,
          action_policy: { execute: :forbidden })
        pin = s.pin_command_flow_view(:blocked_decision_health,
          action: :execute,
          actor: "dispatcher-1")

        receipt = s.append_command_flow_decision(pin)
        decisions = s.command_flow_decisions(
          owner: :commanded_reminders,
          status: :blocked,
          meaning_status: :unknown
        )

        expect(receipt).to be_appended
        expect(decisions.size).to eq(1)
        expect(decisions.first.status).to eq(:blocked)
        expect(decisions.first.errors.map { |error| error[:code] })
          .to include(:action_forbidden)
      ensure
        s&.close
      end

      it "filters command flow decisions by temporal window and limit" do
        s = described_class.new
        s.register_command_flow_view(:first_decision_health,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        s.register_command_flow_view(:second_decision_health,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        first_pin = s.pin_command_flow_view(:first_decision_health, action: :inspect)
        second_pin = s.pin_command_flow_view(:second_decision_health, action: :inspect)
        since = Time.now.utc - 60

        s.append_command_flow_decision(first_pin)
        s.append_command_flow_decision(second_pin)

        decisions = s.command_flow_decisions(
          owner: :commanded_reminders,
          since: since,
          as_of: Time.now.utc + 60,
          limit: 1
        )

        expect(decisions.size).to eq(1)
        expect(decisions.first.view_name).to eq(:first_decision_health)
      ensure
        s&.close
      end

      it "raises for malformed command flow decision append input" do
        s = described_class.new

        expect { s.append_command_flow_decision(Object.new) }
          .to raise_error(ArgumentError, /CommandFlowViewPin/)
      ensure
        s&.close
      end

      it "returns an ok empty command flow decision review" do
        s = described_class.new

        review = s.command_flow_decision_review(owner: :commanded_reminders)

        expect(review).to be_frozen
        expect(review).to be_ok
        expect(review[:kind]).to eq(:command_flow_decision_review)
        expect(review.summary).to include(
          total: 0,
          status_count: {},
          meaning_status_count: {},
          view_count: {},
          action_count: {},
          actor_count: {},
          missing_capability_count: 0,
          error_count: 0,
          warning_count: 0,
          latest_generated_at: nil
        )
        expect(review.findings).to eq([])
        expect(review.decisions).to eq([])
        expect(review.to_h).not_to have_key(:fact_id)
        expect(review.to_h).not_to have_key(:value_hash)
        expect(review.to_h).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "reviews command flow decisions with summary metrics and findings" do
        s = described_class.new
        s.register_command_flow_view(:review_health,
          owner: :commanded_reminders,
          action_policy: {
            approve: :requires_pinned_horizon,
            required_capabilities: [:dispatch_review]
          })
        s.register_command_flow_view(:warning_health,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        pinned = s.pin_command_flow_view(:review_health,
          action: :approve,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review])
        blocked = s.pin_command_flow_view(:review_health,
          action: :approve,
          actor: "dispatcher-2",
          capabilities: [])
        warning_pin = Igniter::DurableModel::CommandFlowViewPin.new(
          status: :blocked,
          meaning_status: :unknown,
          name: :warning_health,
          owner: :commanded_reminders,
          action: :inspect,
          actor: "dispatcher-1",
          receipt: { receipt_id: "cfvp_warning" },
          warnings: [{ code: :manual_review, message: "needs review" }]
        )
        pinned_receipt = s.append_command_flow_decision(pinned)
        s.append_command_flow_decision(blocked)
        s.append_command_flow_decision(warning_pin)
        before_decisions = s.command_flow_decisions(owner: :commanded_reminders).size

        review = s.command_flow_decision_review(
          owner: :commanded_reminders,
          since: Time.now.utc - 60,
          as_of: Time.now.utc + 60,
          rules: [
            { name: :total, metric: :total, op: :>=, value: 3, severity: :warning },
            { name: :blocked, metric: :status_count, status: :blocked, op: :>=, value: 2 },
            { name: :unknown, metric: :meaning_status_count, meaning_status: :unknown, op: :>=, value: 2 },
            { name: :view, metric: :view_count, view_name: :review_health, op: :>=, value: 2 },
            { name: :action, metric: :action_count, action: :approve, op: :>=, value: 2 },
            { name: :actor, metric: :actor_count, actor: "dispatcher-1", op: :>=, value: 2 },
            { name: :missing, metric: :missing_capability_count, op: :>=, value: 1 },
            { name: :errors, metric: :error_count, op: :>=, value: 1 },
            { name: :warnings, metric: :warning_count, op: :>=, value: 1, severity: :critical }
          ],
          metadata: { dashboard: :ops }
        )
        after_decisions = s.command_flow_decisions(owner: :commanded_reminders).size

        expect(review).to be_critical
        expect(review.summary).to include(
          total: 3,
          missing_capability_count: 1,
          error_count: 1,
          warning_count: 1
        )
        expect(review.summary[:status_count]).to include(pinned: 1, blocked: 2)
        expect(review.summary[:meaning_status_count]).to include(reproducible: 1, unknown: 2)
        expect(review.summary[:view_count]).to include(review_health: 2, warning_health: 1)
        expect(review.summary[:action_count]).to include(approve: 2, inspect: 1)
        expect(review.summary[:actor_count]).to include(:"dispatcher-1" => 2)
        expect(review.findings.map { |finding| finding[:name] }).to include(
          :total,
          :blocked,
          :unknown,
          :view,
          :action,
          :actor,
          :missing,
          :errors,
          :warnings
        )
        expect(review.findings.last).to include(status: :matched, severity: :critical)
        expect(review.metadata).to eq(dashboard: :ops)
        expect(after_decisions).to eq(before_decisions)

        filtered = s.command_flow_decision_review(
          owner: :commanded_reminders,
          decision_receipt_id: pinned_receipt.decision_receipt_id,
          limit: 1
        )
        expect(filtered.decisions.size).to eq(1)
        expect(filtered.decisions.first[:decision_receipt_id]).to eq(pinned_receipt.decision_receipt_id)
      ensure
        s&.close
      end

      it "raises for malformed command flow decision review rules" do
        s = described_class.new

        expect do
          s.command_flow_decision_review(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :mystery, op: :>=, value: 1 }])
        end.to raise_error(ArgumentError, /metric/)
        expect do
          s.command_flow_decision_review(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :total, op: :between, value: 1 }])
        end.to raise_error(ArgumentError, /operator/)
        expect do
          s.command_flow_decision_review(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :total, op: :>= }])
        end.to raise_error(ArgumentError, /requires value/)
        expect do
          s.command_flow_decision_review(owner: :commanded_reminders,
            rules: [{ name: :bad, metric: :status_count, op: :>=, value: 1 }])
        end.to raise_error(ArgumentError, /requires status/)
      ensure
        s&.close
      end

      it "builds view-only command flow evidence profiles" do
        s = described_class.new
        s.register_command_flow_view(:profile_view_only,
          owner: :commanded_reminders,
          action_policy: { inspect: true })

        profile = s.command_flow_evidence_profile(view_name: :profile_view_only)

        expect(profile).to be_frozen
        expect(profile).to be_ok
        expect(profile.meaning_status).to eq(:live)
        expect(profile[:kind]).to eq(:command_flow_evidence_profile)
        expect(profile.view[:name]).to eq(:profile_view_only)
        expect(profile.pin).to be_nil
        expect(profile.review[:summary][:total]).to eq(0)
        expect(profile.decisions).to eq([])
        expect(profile.packets.map { |packet| packet[:kind] }).to include(
          :command_flow_view_evidence,
          :command_flow_decision_review_evidence
        )
        expect(profile.links.first).to include(
          rel: :derived_from,
          from: "durable-model://command-flow/views/profile_view_only",
          to: "durable-model://command-flow/owners/commanded_reminders"
        )
        expect(profile.to_h).not_to have_key(:fact_id)
        expect(profile.to_h).not_to have_key(:value_hash)
        expect(profile.to_h).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "builds command flow evidence profiles with pins, reviews, packets, and links" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.register_command_flow_view(:profile_health,
          owner: :commanded_reminders,
          command: :complete,
          action_policy: {
            mutate: :requires_pinned_horizon,
            required_capabilities: [:dispatch_review]
          },
          rules: [{
            name: :denials,
            metric: :status_count,
            status: :policy_denied,
            op: :>=,
            value: 1,
            severity: :warning
          }])
        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [],
          mode: :apply,
          audit: true)
        stored_pin = s.pin_command_flow_view(:profile_health,
          action: :mutate,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review])
        receipt = s.append_command_flow_decision(stored_pin)
        before_decisions = s.command_flow_decisions(owner: :commanded_reminders).size
        before_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size

        profile = s.command_flow_evidence_profile(
          view_name: :profile_health,
          action: :mutate,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review],
          decision_receipt_id: receipt.decision_receipt_id,
          decision_rules: [{
            name: :decision_present,
            metric: :total,
            op: :>=,
            value: 1,
            severity: :critical
          }],
          metadata: { source: :ops_dashboard }
        )
        after_decisions = s.command_flow_decisions(owner: :commanded_reminders).size
        after_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        record = s.read(CommandedReminder, key: "r1")

        expect(profile).to be_critical
        expect(profile.meaning_status).to eq(:reproducible)
        expect(profile.metadata).to eq(source: :ops_dashboard)
        expect(profile.view[:status]).to eq(:warning)
        expect(profile.pin[:status]).to eq(:pinned)
        expect(profile.review[:findings].first).to include(
          name: :decision_present,
          severity: :critical
        )
        expect(profile.decisions.size).to eq(1)
        expect(profile.decisions.first[:decision_receipt_id]).to eq(receipt.decision_receipt_id)
        expect(profile.horizon[:pin]).to include(mode: :reproducible)
        expect(profile.packets.map { |packet| packet[:kind] }).to include(
          :command_flow_view_evidence,
          :command_flow_pin_evidence,
          :command_flow_decision_review_evidence,
          :command_flow_decision_evidence
        )
        expect(profile.packets).to all(include(policy: {
          store_fact_exposed: false,
          value_hash_exposed: false
        }))
        expect(profile.packets.first[:subject]).to eq(
          "durable-model://command-flow/views/profile_health"
        )
        expect(profile.links).to include(
          rel: :identified_by,
          from: "durable-model://command-flow/decisions/#{receipt.decision_receipt_id}",
          to: "durable-model://command-flow/decision-receipts/#{receipt.decision_receipt_id}"
        )
        expect(profile.to_h.dig(:packets, 0, :payload)).not_to have_key(:fact_id)
        expect(record.status).to eq(:open)
        expect(after_decisions).to eq(before_decisions)
        expect(after_activity).to eq(before_activity)
      ensure
        s&.close
      end

      it "builds blocked command flow evidence profiles conservatively" do
        s = described_class.new
        s.register_command_flow_view(:blocked_profile,
          owner: :commanded_reminders,
          action_policy: { execute: :forbidden })

        profile = s.command_flow_evidence_profile(
          view_name: :blocked_profile,
          action: :execute
        )

        expect(profile).to be_blocked
        expect(profile.meaning_status).to eq(:unknown)
        expect(profile.pin[:errors].map { |error| error[:code] }).to include(:action_forbidden)
      ensure
        s&.close
      end

      it "keeps mixed meaning status for evidence profiles with mixed decisions" do
        s = described_class.new
        s.register_command_flow_view(:mixed_profile,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        reproducible_pin = s.pin_command_flow_view(:mixed_profile, action: :inspect)
        unknown_pin = Igniter::DurableModel::CommandFlowViewPin.new(
          status: :blocked,
          meaning_status: :live,
          name: :mixed_profile,
          owner: :commanded_reminders,
          action: :inspect,
          receipt: { receipt_id: "cfvp_live" }
        )
        s.append_command_flow_decision(reproducible_pin)
        s.append_command_flow_decision(unknown_pin)

        profile = s.command_flow_evidence_profile(view_name: :mixed_profile)

        expect(profile.meaning_status).to eq(:mixed)
      ensure
        s&.close
      end

      it "exports command flow evidence profiles deterministically" do
        s = described_class.new
        s.register_command_flow_view(:export_profile,
          owner: :commanded_reminders,
          action_policy: {
            inspect: true,
            required_capabilities: [:dispatch_review]
          })
        pin = s.pin_command_flow_view(:export_profile,
          action: :inspect,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review])
        receipt = s.append_command_flow_decision(pin)
        profile = s.command_flow_evidence_profile(
          view_name: :export_profile,
          action: :inspect,
          actor: "dispatcher-1",
          capabilities: [:dispatch_review],
          decision_receipt_id: receipt.decision_receipt_id
        )

        first = s.export_command_flow_evidence_profile(profile,
          metadata: { source: :spec })
        second = s.export_command_flow_evidence_profile(profile,
          metadata: { source: :spec })

        expect(first).to be_frozen
        expect(first[:kind]).to eq(:command_flow_evidence_export)
        expect(first.export_id).to start_with("cfe_")
        expect(first.export_id).to eq(second.export_id)
        expect(first.content_hash).to eq(second.content_hash)
        expect(first.canonical_json).to eq(second.canonical_json)
        expect(first.profile[:kind]).to eq(:command_flow_evidence_profile)
        expect(first.packets).not_to be_empty
        expect(first.links).not_to be_empty
        expect(first.metadata).to eq(source: :spec)
        expect(first.to_h).not_to have_key(:fact_id)
        expect(first.to_h).not_to have_key(:value_hash)
        expect(first.to_h).not_to have_key(:causation)
      ensure
        s&.close
      end

      it "exports summary-only command flow evidence with redactions" do
        s = described_class.new
        s.register_command_flow_view(:summary_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        pin = s.pin_command_flow_view(:summary_export, action: :inspect)
        s.append_command_flow_decision(pin)
        profile = s.command_flow_evidence_profile(
          view_name: :summary_export,
          action: :inspect
        )

        export = s.export_command_flow_evidence_profile(profile,
          privacy: :summary_only)

        expect(export.privacy).to eq(:summary_only)
        expect(export.profile).to include(:status, :meaning_status, :horizon, :review, :links)
        expect(export.profile).not_to have_key(:view)
        expect(export.profile).not_to have_key(:pin)
        expect(export.profile).not_to have_key(:decisions)
        expect(export.packets).to all(satisfy { |packet| !packet.key?(:payload) })
        expect(export.redactions.map { |redaction| redaction[:action] }).to include(:removed)
        expect(export.diagnostics.map { |diagnostic| diagnostic[:code] }).to include(:evidence_payloads_omitted)
      ensure
        s&.close
      end

      it "exports hash-payload command flow evidence with payload hashes" do
        s = described_class.new
        s.register_command_flow_view(:hashed_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        profile = s.command_flow_evidence_profile(
          view_name: :hashed_export,
          action: :inspect
        )

        export = s.export_command_flow_evidence_profile(profile,
          privacy: :hash_payloads)

        expect(export.privacy).to eq(:hash_payloads)
        expect(export.profile[:view]).to have_key(:content_hash)
        expect(export.profile[:pin]).to have_key(:content_hash)
        expect(export.packets).to all(include(:payload_hash))
        expect(export.packets).to all(satisfy { |packet| !packet.key?(:payload) })
        expect(export.redactions.map { |redaction| redaction[:action] }).to include(:hashed)
        expect(export.diagnostics.map { |diagnostic| diagnostic[:code] }).to include(:evidence_payloads_hashed)
      ensure
        s&.close
      end

      it "exports command flow evidence without packets or decisions" do
        s = described_class.new
        s.register_command_flow_view(:omitted_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        pin = s.pin_command_flow_view(:omitted_export, action: :inspect)
        s.append_command_flow_decision(pin)
        profile = s.command_flow_evidence_profile(
          view_name: :omitted_export,
          action: :inspect
        )

        export = s.export_command_flow_evidence_profile(profile,
          include_packets: false,
          include_decisions: false)

        expect(export.packets).to eq([])
        expect(export.profile[:decisions]).to eq([])
        expect(export.redactions).to include(
          include(path: [:packets], action: :removed),
          include(path: [:decisions], action: :removed)
        )
        expect(export.diagnostics.map { |diagnostic| diagnostic[:code] }).to include(
          :evidence_packets_omitted
        )
      ensure
        s&.close
      end

      it "reports export diagnostics for blocked, critical, and empty evidence" do
        s = described_class.new
        s.register_command_flow_view(:diagnostic_export,
          owner: :commanded_reminders,
          action_policy: { execute: :forbidden })

        export = s.command_flow_evidence_export(
          view_name: :diagnostic_export,
          action: :execute,
          decision_rules: [{
            name: :empty,
            metric: :total,
            op: :==,
            value: 0,
            severity: :critical
          }]
        )

        expect(export.status).to eq(:critical)
        expect(export.meaning_status).to eq(:unknown)
        expect(export.diagnostics.map { |diagnostic| diagnostic[:code] }).to include(
          :evidence_profile_blocked,
          :evidence_meaning_incomplete,
          :evidence_review_critical,
          :evidence_decisions_empty
        )
      ensure
        s&.close
      end

      it "raises for unknown command flow evidence export privacy" do
        s = described_class.new
        s.register_command_flow_view(:bad_privacy_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        profile = s.command_flow_evidence_profile(view_name: :bad_privacy_export)

        expect do
          s.export_command_flow_evidence_profile(profile, privacy: :classified)
        end.to raise_error(ArgumentError, /privacy/)
      ensure
        s&.close
      end

      it "does not mutate history or records while exporting evidence" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.register_command_flow_view(:readonly_export,
          owner: :commanded_reminders,
          command: :complete,
          action_policy: { inspect: true })
        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          mode: :apply,
          audit: true)
        before_decisions = s.command_flow_decisions(owner: :commanded_reminders).size
        before_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        before_status = s.read(CommandedReminder, key: "r1").status

        s.command_flow_evidence_export(
          view_name: :readonly_export,
          action: :inspect
        )
        after_decisions = s.command_flow_decisions(owner: :commanded_reminders).size
        after_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        record = s.read(CommandedReminder, key: "r1")

        expect(after_decisions).to eq(before_decisions)
        expect(after_activity).to eq(before_activity)
        expect(record.status).to eq(before_status)
      ensure
        s&.close
      end

      it "verifies valid and invalid command flow evidence exports" do
        s = described_class.new
        s.register_command_flow_view(:verify_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        export = s.command_flow_evidence_export(view_name: :verify_export)
        invalid_export = Igniter::DurableModel::CommandFlowEvidenceExport.new(
          export_id: export.export_id,
          profile_kind: export.profile_kind,
          owner: export.owner,
          view_name: export.view_name,
          action: export.action,
          actor: export.actor,
          status: export.status,
          meaning_status: export.meaning_status,
          privacy: export.privacy,
          generated_at: export.generated_at,
          content_hash: export.content_hash,
          canonical_json: "#{export.canonical_json}\n",
          profile: export.profile,
          packets: export.packets,
          links: export.links,
          diagnostics: export.diagnostics,
          redactions: export.redactions,
          metadata: export.metadata
        )

        valid = s.verify_command_flow_evidence_export(export,
          metadata: { checked_by: :spec })
        invalid = s.verify_command_flow_evidence_export(invalid_export)

        expect(valid).to be_frozen
        expect(valid).to be_valid
        expect(valid[:kind]).to eq(:command_flow_evidence_export_verification)
        expect(valid.expected_hash).to eq(export.content_hash)
        expect(valid.actual_hash).to eq(export.content_hash)
        expect(valid.metadata).to eq(checked_by: :spec)
        expect(invalid).to be_invalid
        expect(invalid.actual_hash).not_to eq(invalid.expected_hash)
        expect(invalid.diagnostics.map { |diagnostic| diagnostic[:code] })
          .to include(:evidence_export_hash_mismatch)
      ensure
        s&.close
      end

      it "archives valid command flow evidence exports explicitly" do
        s = described_class.new
        s.register(CommandedReminder)
        s.write(CommandedReminder, key: "r1", id: "r1", title: "Buy milk", status: :open)
        s.register_command_flow_view(:archive_export,
          owner: :commanded_reminders,
          command: :complete,
          action_policy: { inspect: true })
        s.command_flow(CommandedReminder, :complete,
          key: "r1",
          capabilities: [:reminder_complete],
          mode: :apply,
          audit: true)
        export = s.command_flow_evidence_export(
          view_name: :archive_export,
          action: :inspect,
          actor: "dispatcher-1",
          privacy: :summary_only,
          metadata: { source: :export })
        before_decisions = s.command_flow_decisions(owner: :commanded_reminders).size
        before_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        before_status = s.read(CommandedReminder, key: "r1").status

        receipt = s.archive_command_flow_evidence_export(export,
          metadata: { source: :archive, case_id: "dispatch-42" })
        archives = s.command_flow_evidence_archives(
          owner: :commanded_reminders,
          view_name: :archive_export,
          action: :inspect,
          actor: "dispatcher-1",
          export_id: export.export_id,
          content_hash: export.content_hash,
          privacy: :summary_only,
          status: export.status,
          meaning_status: export.meaning_status
        )
        after_decisions = s.command_flow_decisions(owner: :commanded_reminders).size
        after_activity = s.command_lifecycle_events(
          owner: :commanded_reminders,
          command: :complete
        ).size
        record = s.read(CommandedReminder, key: "r1")

        expect(receipt).to be_frozen
        expect(receipt).to be_archived
        expect(receipt[:kind]).to eq(:command_flow_evidence_archive_receipt)
        expect(receipt.archive_receipt_id).to start_with("cfea_")
        expect(receipt.export_id).to eq(export.export_id)
        expect(receipt.content_hash).to eq(export.content_hash)
        expect(receipt.metadata).to include(source: :archive, case_id: "dispatch-42")
        expect(receipt.to_h).not_to have_key(:fact_id)
        expect(receipt.to_h).not_to have_key(:value_hash)
        expect(receipt.to_h).not_to have_key(:causation)
        expect(archives.size).to eq(1)
        expect(archives.first).to be_a(Igniter::DurableModel::CommandFlowEvidenceArchive)
        expect(archives.first.to_h).to include(
          owner: :commanded_reminders,
          view_name: :archive_export,
          action: :inspect,
          actor: "dispatcher-1",
          export_id: export.export_id,
          content_hash: export.content_hash,
          privacy: :summary_only,
          status: export.status,
          meaning_status: export.meaning_status,
          profile_kind: :command_flow_evidence_profile,
          canonical_json: export.canonical_json,
          store_fact_exposed: false,
          value_hash_exposed: false
        )
        expect(archives.first.metadata).to include(source: :archive, case_id: "dispatch-42")
        expect(s.verify_command_flow_evidence_archive(archives.first)).to be_valid
        expect(after_decisions).to eq(before_decisions)
        expect(after_activity).to eq(before_activity)
        expect(record.status).to eq(before_status)
      ensure
        s&.close
      end

      it "rejects invalid command flow evidence exports without archiving" do
        s = described_class.new
        s.register_command_flow_view(:invalid_archive_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        export = s.command_flow_evidence_export(view_name: :invalid_archive_export)
        invalid_export = Igniter::DurableModel::CommandFlowEvidenceExport.new(
          export_id: export.export_id,
          profile_kind: export.profile_kind,
          owner: export.owner,
          view_name: export.view_name,
          action: export.action,
          actor: export.actor,
          status: export.status,
          meaning_status: export.meaning_status,
          privacy: export.privacy,
          generated_at: export.generated_at,
          content_hash: export.content_hash,
          canonical_json: "#{export.canonical_json} ",
          profile: export.profile,
          packets: export.packets,
          links: export.links,
          diagnostics: export.diagnostics,
          redactions: export.redactions,
          metadata: export.metadata
        )

        receipt = s.archive_command_flow_evidence_export(invalid_export)

        expect(receipt).to be_rejected
        expect(receipt.diagnostics.map { |diagnostic| diagnostic[:code] })
          .to include(:evidence_export_hash_mismatch)
        expect(s.command_flow_evidence_archives(owner: :commanded_reminders)).to eq([])
      ensure
        s&.close
      end

      it "filters command flow evidence archives by temporal window and limit" do
        s = described_class.new
        s.register_command_flow_view(:first_archive_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        s.register_command_flow_view(:second_archive_export,
          owner: :commanded_reminders,
          action_policy: { inspect: true })
        first = s.command_flow_evidence_export(view_name: :first_archive_export)
        second = s.command_flow_evidence_export(view_name: :second_archive_export)
        since = Time.now.utc - 60

        s.archive_command_flow_evidence_export(first)
        s.archive_command_flow_evidence_export(second)

        archives = s.command_flow_evidence_archives(
          owner: :commanded_reminders,
          since: since,
          as_of: Time.now.utc + 60,
          limit: 1
        )

        expect(archives.size).to eq(1)
        expect(archives.first.view_name).to eq(:first_archive_export)
      ensure
        s&.close
      end
    end

    describe "#descriptor_snapshot" do
      it "returns a Hash with :stores, :histories, :commands, and :effects keys" do
        snap = store.descriptor_snapshot
        expect(snap).to have_key(:stores)
        expect(snap).to have_key(:histories)
        expect(snap).to have_key(:commands)
        expect(snap).to have_key(:effects)
      end

      it "descriptor_snapshot[:stores] contains the Reminder descriptor" do
        snap = store.descriptor_snapshot
        expect(snap[:stores]).to have_key(Reminder.store_name)
      end

      it "Reminder descriptor has kind: :store and expected name" do
        desc = store.descriptor_snapshot[:stores][Reminder.store_name]
        expect(desc[:kind]).to eq(:store)
        expect(desc[:name]).to eq(Reminder.store_name)
      end

      it "Reminder descriptor carries a producer from igniter_companion" do
        desc = store.descriptor_snapshot[:stores][Reminder.store_name]
        expect(desc[:producer][:system]).to eq(:igniter_companion)
        expect(desc[:producer][:name]).to   be_a(String)
      end

      it "TrackerLog descriptor appears in :histories" do
        s = described_class.new
        s.register(TrackerLog)
        desc = s.descriptor_snapshot[:histories][TrackerLog.store_name]
        expect(desc[:kind]).to eq(:history)
        expect(desc[:name]).to eq(TrackerLog.store_name)
      ensure
        s&.close
      end

      it "TrackerLog descriptor key equals the declared partition_key" do
        s = described_class.new
        s.register(TrackerLog)
        desc = s.descriptor_snapshot[:histories][TrackerLog.store_name]
        expect(desc[:key]).to eq(TrackerLog._partition_key)
      ensure
        s&.close
      end

      it "includes command and effect descriptor registries" do
        s = described_class.new
        s.register(CommandedReminder)
        snap = s.descriptor_snapshot

        expect(snap[:commands][:commanded_reminders]).to have_key(:complete)
        expect(snap[:effects][:commanded_reminders]).to have_key(:complete)
      ensure
        s&.close
      end
    end

    describe "descriptor field content" do
      subject(:record_class) { Igniter::Companion::Record.from_manifest(RECORD_MANIFEST) }

      it "store descriptor fields list matches manifest fields" do
        s = described_class.new
        s.register(record_class)
        desc = s.descriptor_snapshot[:stores][record_class.store_name]
        field_names = desc[:fields].map { |f| f[:name] }
        expect(field_names).to eq(record_class._fields.keys)
      ensure
        s&.close
      end

      it "store descriptor carries type metadata for typed fields" do
        s = described_class.new
        s.register(record_class)
        desc  = s.descriptor_snapshot[:stores][record_class.store_name]
        title = desc[:fields].find { |f| f[:name] == :title }
        expect(title[:type]).to eq(:string)
      ensure
        s&.close
      end

      it "store descriptor carries values: for enum fields" do
        s = described_class.new
        s.register(record_class)
        desc   = s.descriptor_snapshot[:stores][record_class.store_name]
        status = desc[:fields].find { |f| f[:name] == :status }
        expect(status[:values]).to eq(%i[open done])
      ensure
        s&.close
      end
    end

    describe "register idempotency with descriptors" do
      it "calling register twice does not create duplicate store descriptors" do
        s = described_class.new
        s.register(Reminder)
        s.register(Reminder)
        snap = s.descriptor_snapshot
        expect(snap[:stores].keys.count { |k| k == Reminder.store_name }).to eq(1)
      ensure
        s&.close
      end
    end
  end

  describe "from_manifest with relations → register → typed resolve (end-to-end)" do
    RELATION_MANIFEST = {
      storage: { shape: :store, name: :wiki_pages, key: :id },
      fields: [
        { name: :id,    attributes: {} },
        { name: :title, attributes: { type: :string } }
      ],
      scopes: [],
      indexes: [],
      commands: [],
      relations: [
        {
          name: :revisions_by_page,
          attributes: {
            kind: :event_owner, to: :wiki_revisions,
            join: { id: :page_id }, cardinality: :one_to_many
          }
        }
      ]
    }.freeze

    REVISION_MANIFEST = {
      storage: { shape: :store, name: :wiki_revisions, key: :id },
      fields: [
        { name: :id,      attributes: {} },
        { name: :page_id, attributes: {} },
        { name: :body,    attributes: { type: :string } }
      ],
      scopes: [],
      indexes: [],
      commands: [],
      relations: []
    }.freeze

    it "from_manifest parses relations and register auto-wires them" do
      wiki_page     = Igniter::Companion.from_manifest(RELATION_MANIFEST)
      wiki_revision = Igniter::Companion.from_manifest(REVISION_MANIFEST)

      s = described_class.new
      s.register(wiki_page)
      s.register(wiki_revision)

      s.write(wiki_revision, key: "r1", id: "r1", page_id: "p1", body: "First draft")
      s.write(wiki_revision, key: "r2", id: "r2", page_id: "p1", body: "Second draft")

      result = s.resolve(:revisions_by_page, from: "p1")
      expect(result.size).to eq(2)
      expect(result).to all(be_a(wiki_revision))
      expect(result.map(&:body)).to contain_exactly("First draft", "Second draft")
    ensure
      s&.close
    end

    it "relation_snapshot is populated after register" do
      wiki_page = Igniter::Companion.from_manifest(RELATION_MANIFEST)

      s = described_class.new
      s.register(wiki_page)

      expect(s._relations.keys).to include(:revisions_by_page)
    ensure
      s&.close
    end
  end
end
