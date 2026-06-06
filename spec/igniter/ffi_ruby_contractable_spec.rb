# frozen_string_literal: true

require "spec_helper"
require_relative "../../igniter-lang/experiments/runtime_machine_memory_proof/compiled_program"
require_relative "../../igniter-lang/experiments/runtime_machine_memory_proof/ffi_ruby_proof"

RSpec.describe "FFI Ruby Contractable Proof — ESCAPE call discipline" do
  # ---------------------------------------------------------------------------
  # Shared machine setup
  # ---------------------------------------------------------------------------
  def build_machine
    backend = RuntimeMachineMemoryProof::MemoryTBackend.new
    m = RuntimeMachineMemoryProof::RuntimeMachine.new(
      machine_id: "ffi-machine-001",
      session_id: "ffi-session-001",
      backend:    backend
    )
    m.boot
    m
  end

  let(:machine) { build_machine }
  let(:backend) { machine.backend }

  let(:order_adapter) do
    RuntimeMachineMemoryProof::FFIAdapter.new(
      RuntimeMachineMemoryProof::OrderLookupFFI,
      RuntimeMachineMemoryProof::HostStubs::OrderLookup
    )
  end

  let(:assign_adapter) do
    RuntimeMachineMemoryProof::FFIAdapter.new(
      RuntimeMachineMemoryProof::AssignTechnicianFFI,
      RuntimeMachineMemoryProof::HostStubs::AssignTechnician
    )
  end

  def all_obs
    backend.entries.map { |e| e.fetch(:packet) }
  end

  # ===========================================================================
  # Section 1: FFIRequirement declaration
  # ===========================================================================
  describe "FFIRequirement declaration" do
    it "OrderLookupFFI has effects: read, no capabilities, no audit" do
      ffi = RuntimeMachineMemoryProof::OrderLookupFFI
      expect(ffi.effects).to eq(["read"])
      expect(ffi.capabilities).to be_empty
      expect(ffi.audit).to be false
      expect(ffi.receipt_lifecycle).to eq("session")
    end

    it "AssignTechnicianFFI has effects: write, capability: dispatch_assign, audit: true" do
      ffi = RuntimeMachineMemoryProof::AssignTechnicianFFI
      expect(ffi.effects).to eq(["write"])
      expect(ffi.capabilities).to include("dispatch_assign")
      expect(ffi.audit).to be true
      expect(ffi.receipt_lifecycle).to eq("audit")
    end

    it "FFIRequirement.to_descriptor includes fragment_class: escape" do
      expect(order_adapter.requirement.to_descriptor.fetch(:fragment_class)).to eq("escape")
    end

    it "emits descriptor_observation when registered" do
      machine.register_ffi(order_adapter)
      desc_obs = machine.ffi_descriptor_obs(order_adapter)
      expect(desc_obs.kind).to eq("descriptor_observation")
      expect(desc_obs.subject).to eq("ffi://order_lookup")
      expect(desc_obs.payload["fragment_class"]).to eq("escape")
      expect(desc_obs.temporal.fetch("lifecycle")).to eq("load")
    end
  end

  # ===========================================================================
  # Section 2: Call discipline — success path (no capability required)
  # ===========================================================================
  describe "OrderLookup — success path (PROP-012 §Contractable FFI)" do
    let(:gate) { RuntimeMachineMemoryProof::CapabilityGate.new([]) }

    before do
      machine.register_ffi(order_adapter)
      @result = machine.call_ffi("order_lookup", { order_id: "ord-42" }, gate: gate)
    end

    it "returns status: ok" do
      expect(@result.fetch(:status)).to eq(:ok)
    end

    it "returns the host output" do
      expect(@result.fetch(:output)).to include(order_id: "ord-42", status: "open")
    end

    it "emits intent_observation before receipt" do
      intent = all_obs.find { |p| p.kind == "intent_observation" }
      expect(intent).not_to be_nil
      expect(intent.subject).to eq("ffi://order_lookup/intent")
      expect(intent.temporal.fetch("lifecycle")).to eq("local")
      expect(intent.payload["ffi_id"]).to eq("order_lookup")
    end

    it "emits receipt_observation after host call" do
      receipt = all_obs.find { |p| p.kind == "receipt_observation" && p.subject.include?("order_lookup") }
      expect(receipt).not_to be_nil
      expect(receipt.subject).to eq("ffi://order_lookup/receipt")
      expect(receipt.temporal.fetch("lifecycle")).to eq("session")
    end

    it "receipt links caused_by -> intent" do
      intent  = @result.fetch(:intent_obs)
      receipt = @result.fetch(:receipt_obs)
      caused = receipt.links.find { |l| l["rel"] == "caused_by" }
      expect(caused).not_to be_nil
      expect(caused["ref"]).to eq(intent.id)
    end

    it "receipt links produced_by -> ffi uri" do
      receipt = @result.fetch(:receipt_obs)
      produced = receipt.links.find { |l| l["rel"] == "produced_by" }
      expect(produced).not_to be_nil
      expect(produced["ref"]).to eq("ffi://order_lookup")
    end

    it "receipt carries output in payload" do
      receipt = @result.fetch(:receipt_obs)
      expect(receipt.payload["output"]["order_id"]).to eq("ord-42")
    end

    it "observation sequence: intent before receipt" do
      entries = backend.entries
      intent_seq  = entries.find { |e| e[:packet].kind == "intent_observation" }&.fetch(:seq_id)
      receipt_seq = entries.find { |e| e[:packet].kind == "receipt_observation" && e[:packet].subject.include?("ffi://") }&.fetch(:seq_id)
      expect(intent_seq).to be < receipt_seq
    end

    it "no failure_observation emitted on success" do
      failures = all_obs.select { |p| p.kind == "failure_observation" }
      expect(failures).to be_empty
    end
  end

  # ===========================================================================
  # Section 3: Capability gate — missing capability → denied
  # ===========================================================================
  describe "AssignTechnician — capability denied (OOF gate)" do
    let(:empty_gate) { RuntimeMachineMemoryProof::CapabilityGate.new([]) }

    before do
      machine.register_ffi(assign_adapter)
      @result = machine.call_ffi(
        "assign_technician",
        { order_id: "ord-99", technician_id: "t-17" },
        gate: empty_gate
      )
    end

    it "returns status: denied" do
      expect(@result.fetch(:status)).to eq(:denied)
    end

    it "returns reason_code: capability.denied" do
      expect(@result.fetch(:reason_code)).to eq("capability.denied")
    end

    it "emits failure_observation with reason_code capability.denied" do
      failure = all_obs.find { |p| p.kind == "failure_observation" }
      expect(failure).not_to be_nil
      expect(failure.payload["reason_code"]).to eq("capability.denied")
      expect(failure.payload["missing_caps"]).to include("dispatch_assign")
      expect(failure.temporal.fetch("lifecycle")).to eq("session")
    end

    it "failure links caused_by -> intent" do
      intent  = all_obs.find { |p| p.kind == "intent_observation" }
      failure = @result.fetch(:failure_obs)
      caused = failure.links.find { |l| l["rel"] == "caused_by" }
      expect(caused["ref"]).to eq(intent.id)
    end

    it "does NOT emit an ffi receipt_observation" do
      receipts = all_obs.select { |p| p.kind == "receipt_observation" && p.subject.start_with?("ffi://") }
      expect(receipts).to be_empty
    end
  end

  # ===========================================================================
  # Section 4: Capability grant → success with audit receipt
  # ===========================================================================
  describe "AssignTechnician — granted capability → audit receipt" do
    let(:authorized_gate) do
      RuntimeMachineMemoryProof::CapabilityGate.new(["dispatch_assign"])
    end

    before do
      machine.register_ffi(assign_adapter)
      @result = machine.call_ffi(
        "assign_technician",
        { order_id: "ord-99", technician_id: "t-17" },
        gate: authorized_gate
      )
    end

    it "returns status: ok" do
      expect(@result.fetch(:status)).to eq(:ok)
    end

    it "receipt_observation has lifecycle: audit (audit: true)" do
      receipt = @result.fetch(:receipt_obs)
      expect(receipt.temporal.fetch("lifecycle")).to eq("audit")
    end

    it "receipt payload contains assignment_id" do
      receipt = @result.fetch(:receipt_obs)
      expect(receipt.payload["output"]["assignment_id"]).to include("ord-99")
    end

    it "no failure_observation emitted" do
      failures = all_obs.select { |p| p.kind == "failure_observation" }
      expect(failures).to be_empty
    end
  end

  # ===========================================================================
  # Section 5: Host error → failure_observation (ffi.host_error)
  # ===========================================================================
  describe "Host error propagation" do
    let(:gate) { RuntimeMachineMemoryProof::CapabilityGate.new([]) }

    before do
      machine.register_ffi(order_adapter)
      @result = machine.call_ffi("order_lookup", { order_id: "not_found" }, gate: gate)
    end

    it "returns status: host_error" do
      expect(@result.fetch(:status)).to eq(:host_error)
    end

    it "emits failure_observation with reason_code: ffi.host_error" do
      failure = @result.fetch(:failure_obs)
      expect(failure.payload["reason_code"]).to eq("ffi.host_error")
      expect(failure.payload["error_class"]).to eq("KeyError")
      expect(failure.payload["error_message"]).to include("not found")
    end

    it "failure lifecycle is session" do
      expect(@result.fetch(:failure_obs).temporal.fetch("lifecycle")).to eq("session")
    end

    it "does NOT emit an ffi receipt_observation" do
      receipts = all_obs.select { |p| p.kind == "receipt_observation" && p.subject.start_with?("ffi://") }
      expect(receipts).to be_empty
    end
  end

  # ===========================================================================
  # Section 6: Unregistered FFI → failure (OOF gate)
  # ===========================================================================
  describe "Unregistered FFI call → blocked" do
    let(:gate) { RuntimeMachineMemoryProof::CapabilityGate.new([]) }

    it "returns failure when ffi_id not registered" do
      result = machine.call_ffi("ghost_call", { x: 1 }, gate: gate)
      # RuntimeMachine#failure returns { status: "blocked", reason_code: ... }
      expect(result.fetch(:status)).to eq("blocked")
      expect(result.fetch(:reason_code)).to eq("ffi.not_registered")
    end
  end

  # ===========================================================================
  # Section 7: Call conflict → host_error propagated
  # ===========================================================================
  describe "Host error: conflict case (already assigned)" do
    let(:gate) { RuntimeMachineMemoryProof::CapabilityGate.new(["dispatch_assign"]) }

    before do
      machine.register_ffi(assign_adapter)
      @result = machine.call_ffi(
        "assign_technician",
        { order_id: "ord-99", technician_id: "t-conflict" },
        gate: gate
      )
    end

    it "returns status: host_error" do
      expect(@result.fetch(:status)).to eq(:host_error)
    end

    it "failure payload contains error_message from Ruby exception" do
      expect(@result.fetch(:failure_obs).payload["error_message"]).to include("conflict")
    end
  end

  # ===========================================================================
  # Section 8: CapabilityGate — grant/revoke
  # ===========================================================================
  describe "CapabilityGate grant and revoke" do
    let(:gate) { RuntimeMachineMemoryProof::CapabilityGate.new([]) }

    it "check returns :granted when empty required" do
      expect(gate.check([])).to eq(:granted)
    end

    it "check returns [:denied, missing] when cap absent" do
      status, missing = gate.check(["dispatch_assign"])
      expect(status).to eq(:denied)
      expect(missing).to include("dispatch_assign")
    end

    it "check returns :granted after grant" do
      gate.grant("dispatch_assign")
      expect(gate.check(["dispatch_assign"])).to eq(:granted)
    end

    it "check returns :denied after revoke" do
      gate.grant("dispatch_assign")
      gate.revoke("dispatch_assign")
      status, _ = gate.check(["dispatch_assign"])
      expect(status).to eq(:denied)
    end
  end

  # ===========================================================================
  # Section 9: Evidence chain integrity
  # ===========================================================================
  describe "Evidence chain — all FFI observations carry evidence links" do
    let(:gate) { RuntimeMachineMemoryProof::CapabilityGate.new([]) }

    before do
      machine.register_ffi(order_adapter)
      machine.call_ffi("order_lookup", { order_id: "ord-42" }, gate: gate)
    end

    it "intent_observation carries observed_under links" do
      intent = all_obs.find { |p| p.kind == "intent_observation" }
      observed = intent.links.map { |l| l["rel"] }
      expect(observed).to include("observed_under")
    end

    it "receipt_observation carries observed_under links" do
      receipt = all_obs.find { |p| p.kind == "receipt_observation" }
      observed = receipt.links.map { |l| l["rel"] }
      expect(observed).to include("observed_under")
    end

    it "receipt caused_by link points to a real observation in backend" do
      receipt = all_obs.find { |p| p.kind == "receipt_observation" && p.subject.include?("ffi://") }
      caused_link = receipt.links.find { |l| l["rel"] == "caused_by" }
      expect(caused_link).not_to be_nil
      ids = all_obs.map(&:id)
      expect(ids).to include(caused_link["ref"])
    end
  end
end
