# frozen_string_literal: true

require "spec_helper"
require_relative "../../igniter-lang/experiments/runtime_machine_memory_proof/compiled_program"

RSpec.describe "AvailabilityProjection .igapp/ — Window Lifecycle" do
  AVAIL_IGAPP = File.expand_path(
    "../../igniter-lang/fixtures/availability_projection.igapp",
    __dir__
  ).freeze

  AS_OF = "2026-05-05T10:01:00Z"
  DATE  = "2026-05-05"

  def seed_facts(machine, technician_id, date, as_of)
    # GeoSignal facts (lifecycle: :window)
    geo_signals = [
      { "hour" => 8,  "signal" => "available" },
      { "hour" => 9,  "signal" => "busy" },
      { "hour" => 10, "signal" => "available" },
      { "hour" => 11, "signal" => "available" }
    ]
    geo_packet = machine.fact_packet(
      subject: "geo_signal/#{technician_id}/#{date}",
      payload: geo_signals,
      as_of:   as_of
    )
    machine.backend.append(geo_packet)

    # Schedule fact (lifecycle: :durable)
    schedule_packet = machine.fact_packet(
      subject: "schedule/#{technician_id}/#{date}",
      payload: { "working_hours" => [8, 12], "day_off" => false },
      as_of:   as_of
    )
    machine.backend.append(schedule_packet)

    { geo: geo_packet, schedule: schedule_packet }
  end

  subject(:machine) do
    backend = RuntimeMachineMemoryProof::MemoryTBackend.new
    m = RuntimeMachineMemoryProof::RuntimeMachine.new(
      machine_id: "avail-machine-001",
      session_id: "avail-session-001",
      backend:    backend
    )
    m.boot
    m
  end

  let(:backend) { machine.backend }
  let(:program) { RuntimeMachineMemoryProof::CompiledProgram.load_igapp(AVAIL_IGAPP) }

  # ---------------------------------------------------------------------------
  # Artifact structure
  # ---------------------------------------------------------------------------
  describe "Artifact structure (PROP-012)" do
    it "loads without error" do
      expect { program }.not_to raise_error
    end

    it "fragment_class is escape (has window reads)" do
      expect(program.fragment_class).to eq("escape")
    end

    it "oof_count is 0 (no OOF violations)" do
      expect(program.oof_count).to eq(0)
    end

    it "has_window? is true" do
      expect(program.has_window?).to be true
    end

    it "temporal_windows declares the availability window" do
      windows = program.temporal_windows
      expect(windows.length).to eq(1)
      expect(windows.first.fetch("name")).to eq("availability[technician, day]")
      expect(windows.first.fetch("kind")).to eq("calendar")
      expect(windows.first.fetch("unit")).to eq("day")
    end

    it "boundary_descriptors has one descriptor" do
      expect(program.boundary_descriptors.length).to eq(1)
      bd = program.boundary_descriptors.first
      expect(bd.fetch("window_name")).to eq("availability[technician, day]")
      expect(bd.fetch("on_missing_receipt")).to eq("promote")
    end

    it "required_tbackend_caps requires snapshot_enabled" do
      expect(program.required_tbackend_caps.fetch("snapshot_enabled")).to be true
    end

    it "dependency_graph is a DAG (no cycles)" do
      graph = program.dependency_graph
      edges = graph.fetch("edges", [])
      adj = Hash.new { |h, k| h[k] = [] }
      edges.each { |e| adj[e.fetch("from")] << e.fetch("to") }
      visited = {}
      in_stack = {}
      has_cycle = false
      dfs = lambda do |n|
        visited[n] = true; in_stack[n] = true
        adj[n].each { |nb| !visited[nb] ? dfs.call(nb) : (has_cycle = true if in_stack[nb]) }
        in_stack[n] = false
      end
      graph.fetch("nodes", []).each { |n| dfs.call(n) unless visited[n] }
      expect(has_cycle).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Load: descriptor emits escape_set
  # ---------------------------------------------------------------------------
  describe "Load — ESCAPE contract (PROP-011 §Step 2)" do
    before { machine.load_program(program) }

    it "emits descriptor_observation with escape_set: stream_collection" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      desc = obs.find { |p| p.kind == "descriptor_observation" && p.subject.include?("availability") }
      expect(desc).not_to be_nil
      expect(desc.payload["escape_set"]).to include("stream_collection")
      expect(desc.payload["lifecycle"]).to eq("window")
    end

    it "ClassifiedAST shows fragment_class: escape" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      ast = obs.find { |p| p.kind == "platform_observation" && p.subject.start_with?("classified://") }
      expect(ast.payload["fragment_class"]).to eq("escape")
    end
  end

  # ---------------------------------------------------------------------------
  # Evaluate: window lifecycle observations
  # ---------------------------------------------------------------------------
  describe "Evaluate — window lifecycle observations" do
    let(:seeded_facts) { seed_facts(machine, "t-17", DATE, AS_OF) }

    before do
      machine.load_program(program)
      seeded_facts  # seed before evaluate
      @result = machine.evaluate_program(
        "availability_projection",
        { technician_id: "t-17", date: DATE },
        as_of: AS_OF
      )
    end

    it "returns status: ok" do
      expect(@result.fetch(:status)).to eq("ok")
    end

    it "computes available_slots for hours 8..11" do
      slots = @result.dig(:outputs, "available_slots")
      expect(slots).not_to be_nil
      hours = slots.map { |s| s.fetch("hour") }
      expect(hours).to eq([8, 9, 10, 11])
    end

    it "hour 9 is busy (from geo_signal)" do
      slots = @result.dig(:outputs, "available_slots")
      h9 = slots.find { |s| s.fetch("hour") == 9 }
      expect(h9.fetch("status")).to eq("busy")
    end

    it "hours 8, 10, 11 are available" do
      slots = @result.dig(:outputs, "available_slots")
      available = slots.select { |s| s.fetch("status") == "available" }.map { |s| s.fetch("hour") }
      expect(available).to eq([8, 10, 11])
    end

    it "builds a snapshot with technician_id and date" do
      snap = @result.dig(:outputs, "snapshot")
      expect(snap).not_to be_nil
      expect(snap.fetch("technician_id")).to eq("t-17")
      expect(snap.fetch("date")).to eq(DATE)
      expect(snap.fetch("available_count")).to eq(3)
    end

    it "emits value_observation for available_slots with lifecycle: window" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      slots_obs = obs.find { |p| p.kind == "value_observation" && p.subject.include?("available_slots") }
      expect(slots_obs).not_to be_nil
      expect(slots_obs.temporal.fetch("lifecycle")).to eq("window")
    end

    it "emits value_observation for snapshot with lifecycle: durable" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      snap_obs = obs.find { |p| p.kind == "value_observation" && p.subject.include?("snapshot") }
      expect(snap_obs).not_to be_nil
      expect(snap_obs.temporal.fetch("lifecycle")).to eq("durable")
    end
  end

  # ---------------------------------------------------------------------------
  # BoundaryReceipt — window close (PROP-010 DR-2)
  # ---------------------------------------------------------------------------
  describe "BoundaryReceipt — window close (PROP-010 DR-2)" do
    let(:seeded_facts) { seed_facts(machine, "t-17", DATE, AS_OF) }
    let(:window_name)  { "availability[technician, day]" }
    let(:day_end_as_of) { "2026-05-05T23:59:59Z" }

    before do
      machine.load_program(program)
      seeded_facts
      @result = machine.evaluate_program(
        "availability_projection",
        { technician_id: "t-17", date: DATE },
        as_of: AS_OF
      )

      # Collect window observation ids
      obs = backend.entries.map { |e| e.fetch(:packet) }
      @window_obs_ids = obs
        .select { |p| p.kind == "value_observation" && p.temporal.fetch("lifecycle", nil) == "window" }
        .map(&:id)

      # Emit snapshot obs
      snap_payload = @result.dig(:outputs, "snapshot")
      @snap_obs = machine.emit_window_snapshot(
        window_name:      window_name,
        snapshot_payload: snap_payload,
        as_of:            day_end_as_of
      )

      # Emit boundary receipt
      @boundary_receipt = machine.emit_boundary_receipt(
        window_name:    window_name,
        period:         { from: AS_OF, to: day_end_as_of },
        summary_obs_id: @snap_obs.id,
        detail_obs_ids: @window_obs_ids,
        as_of:          day_end_as_of
      )
    end

    it "emits a receipt_observation for the boundary" do
      expect(@boundary_receipt.kind).to eq("receipt_observation")
      expect(@boundary_receipt.subject).to eq("boundary://#{window_name}")
    end

    it "BoundaryReceipt has lifecycle: audit" do
      expect(@boundary_receipt.temporal.fetch("lifecycle")).to eq("audit")
    end

    it "BoundaryReceipt carries summary_ref pointing to snapshot" do
      expect(@boundary_receipt.payload.fetch("summary_ref")).to eq(@snap_obs.id)
    end

    it "BoundaryReceipt detail_count matches window obs count" do
      expect(@boundary_receipt.payload.fetch("detail_count")).to eq(@window_obs_ids.size)
    end

    it "BoundaryReceipt detail_hash is deterministic (same ids → same hash)" do
      expected_hash = RuntimeMachineMemoryProof::Canonical.hash(@window_obs_ids.sort)
      expect(@boundary_receipt.payload.fetch("detail_hash")).to eq(expected_hash)
    end

    it "BoundaryReceipt links include materializes -> snapshot obs" do
      mats = @boundary_receipt.links.select { |l| l.fetch("rel") == "materializes" }
      expect(mats.map { |l| l.fetch("ref") }).to include(@snap_obs.id)
    end

    it "snapshot obs has lifecycle: durable (survives compaction)" do
      expect(@snap_obs.temporal.fetch("lifecycle")).to eq("durable")
    end
  end

  # ---------------------------------------------------------------------------
  # PROP-010 DR-2: compaction eligibility after boundary receipt
  # ---------------------------------------------------------------------------
  describe "Compaction eligibility after BoundaryReceipt (PROP-010 DR-2)" do
    let(:seeded_facts)  { seed_facts(machine, "t-17", DATE, AS_OF) }
    let(:window_name)   { "availability[technician, day]" }
    let(:day_end_as_of) { "2026-05-05T23:59:59Z" }

    before do
      machine.load_program(program)
      seeded_facts
      machine.evaluate_program(
        "availability_projection",
        { technician_id: "t-17", date: DATE },
        as_of: AS_OF
      )

      obs = backend.entries.map { |e| e.fetch(:packet) }
      @window_obs_ids = obs
        .select { |p| p.kind == "value_observation" && p.temporal.fetch("lifecycle", nil) == "window" }
        .map(&:id)
      @window_obs_seq_ids = backend.entries
        .select { |e| @window_obs_ids.include?(e.fetch(:packet).id) }
        .map { |e| e.fetch(:seq_id) }

      snap_obs = machine.emit_window_snapshot(
        window_name:      window_name,
        snapshot_payload: { "available_count" => 3 },
        as_of:            day_end_as_of
      )
      machine.emit_boundary_receipt(
        window_name:    window_name,
        period:         { from: AS_OF, to: day_end_as_of },
        summary_obs_id: snap_obs.id,
        detail_obs_ids: @window_obs_ids,
        as_of:          day_end_as_of
      )
    end

    it "BoundaryReceipt exists in backend (prerequisite for compaction)" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      receipt = obs.find { |p| p.kind == "receipt_observation" && p.subject.include?("boundary") }
      expect(receipt).not_to be_nil
    end

    it "window obs are present before any compaction" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      window_obs = obs.select { |p| @window_obs_ids.include?(p.id) }
      expect(window_obs.size).to eq(@window_obs_ids.size)
    end

    it "snapshot obs is present and lifecycle: durable (GC root; survives compaction)" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      snap = obs.find { |p| p.kind == "fact_observation" && p.subject.include?("snapshot") }
      expect(snap).not_to be_nil
      expect(snap.temporal.fetch("lifecycle")).to eq("durable")
    end

    it "BoundaryReceipt seq_id > last window obs seq_id (receipt after details)" do
      boundary_entry = backend.entries.find do |e|
        e.fetch(:packet).kind == "receipt_observation" &&
          e.fetch(:packet).subject.include?("boundary")
      end
      max_window_seq = @window_obs_seq_ids.max
      expect(boundary_entry.fetch(:seq_id)).to be > max_window_seq
    end
  end

  # ---------------------------------------------------------------------------
  # Reproducibility: same inputs → same available_slots
  # ---------------------------------------------------------------------------
  describe "Reproducibility of window evaluation" do
    it "same inputs + same as_of + same facts → same snapshot payload_hash" do
      seed_facts(machine, "t-17", DATE, AS_OF)
      machine.load_program(program)
      result1 = machine.evaluate_program(
        "availability_projection",
        { technician_id: "t-17", date: DATE },
        as_of: AS_OF
      )

      # Second machine, same state
      backend2 = RuntimeMachineMemoryProof::MemoryTBackend.new
      m2 = RuntimeMachineMemoryProof::RuntimeMachine.new(
        machine_id: "avail-machine-002",
        session_id: "avail-session-002",
        backend: backend2
      )
      m2.boot
      seed_facts(m2, "t-17", DATE, AS_OF)
      m2.load_program(program)
      result2 = m2.evaluate_program(
        "availability_projection",
        { technician_id: "t-17", date: DATE },
        as_of: AS_OF
      )

      snap1 = result1.dig(:outputs, "snapshot")
      snap2 = result2.dig(:outputs, "snapshot")
      expect(RuntimeMachineMemoryProof::Canonical.hash(snap1)).to eq(
        RuntimeMachineMemoryProof::Canonical.hash(snap2)
      )
    end
  end
end
