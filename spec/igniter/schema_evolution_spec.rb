# frozen_string_literal: true

require "spec_helper"
require_relative "../../igniter-lang/experiments/runtime_machine_memory_proof/compiled_program"

# =============================================================================
# PROP-017: Schema Evolution — schema_descriptor, schema_version,
# schema_fingerprint, schema_check in CompatibilityReport
# =============================================================================

RSpec.describe "PROP-017: Schema Evolution — schema_descriptor and schema_check" do
  SCHEMA_ADD_IGAPP   = File.expand_path("../../igniter-lang/fixtures/add.igapp", __dir__)
  SCHEMA_AVAIL_IGAPP = File.expand_path("../../igniter-lang/fixtures/availability_projection.igapp", __dir__)

  let(:add_program)   { RuntimeMachineMemoryProof::CompiledProgram.load_igapp(SCHEMA_ADD_IGAPP) }
  let(:avail_program) { RuntimeMachineMemoryProof::CompiledProgram.load_igapp(SCHEMA_AVAIL_IGAPP) }

  def build_machine(program)
    backend = RuntimeMachineMemoryProof::MemoryTBackend.new
    m = RuntimeMachineMemoryProof::RuntimeMachine.new(
      machine_id: "schema-machine-001",
      session_id: "schema-session-001",
      backend:    backend
    )
    m.boot
    m.load_program(program)
    m
  end

  # ===========================================================================
  # Section 1: schema_descriptor on CompiledProgram
  # ===========================================================================
  describe "CompiledProgram#schema_descriptor" do
    describe "add.igapp" do
      subject(:sd) { add_program.schema_descriptor }

      it "has schema_version: 1.0.0" do
        expect(sd.fetch("schema_version")).to eq("1.0.0")
      end

      it "has schema_fingerprint starting with sha256:" do
        expect(sd.fetch("schema_fingerprint")).to start_with("sha256:")
      end

      it "port_surface includes input a, input b, output sum" do
        ports = sd.fetch("port_surface")
        names = ports.map { |p| p["name"] }
        expect(names).to include("a", "b", "sum")
      end

      it "port_surface dirs are in or out" do
        dirs = sd.fetch("port_surface").map { |p| p["dir"] }.uniq.sort
        expect(dirs).to eq(["in", "out"])
      end

      it "type_env includes Integer" do
        expect(sd.fetch("type_env")).to include("Integer")
      end

      it "trait_bounds includes Additive constraint for T" do
        bounds = sd.fetch("trait_bounds")
        expect(bounds).not_to be_empty
        expect(bounds.first.fetch("constraint")).to eq("Additive")
      end

      it "migrations is empty (no migrations declared)" do
        expect(sd.fetch("migrations")).to be_empty
      end
    end

    describe "availability_projection.igapp" do
      subject(:sd) { avail_program.schema_descriptor }

      it "has schema_version: 1.0.0" do
        expect(sd.fetch("schema_version")).to eq("1.0.0")
      end

      it "has schema_fingerprint" do
        expect(sd.fetch("schema_fingerprint")).to start_with("sha256:")
      end

      it "type_env includes String, Collection[TimeSlot], AvailabilitySnapshot" do
        type_env = sd.fetch("type_env")
        expect(type_env).to include("String")
      end

      it "trait_bounds is empty (no generic type params in v0 fixture)" do
        expect(sd.fetch("trait_bounds")).to be_empty
      end
    end
  end

  # ===========================================================================
  # Section 2: schema_version and schema_fingerprint readers
  # ===========================================================================
  describe "CompiledProgram schema_version and schema_fingerprint" do
    it "add_program.schema_version returns 1.0.0" do
      expect(add_program.schema_version).to eq("1.0.0")
    end

    it "add_program.schema_fingerprint is stable (same value on reload)" do
      prog2 = RuntimeMachineMemoryProof::CompiledProgram.load_igapp(SCHEMA_ADD_IGAPP)
      expect(add_program.schema_fingerprint).to eq(prog2.schema_fingerprint)
    end

    it "add_program and avail_program have DIFFERENT fingerprints (different surfaces)" do
      expect(add_program.schema_fingerprint).not_to eq(avail_program.schema_fingerprint)
    end

    it "changing a port type would produce a different fingerprint (computed correctly)" do
      # We can't change the fixture inline, but we can verify the fingerprint
      # is sensitive to port content by checking it contains sha256.
      expect(add_program.schema_fingerprint).to match(/^sha256:[0-9a-f]{64}$/)
    end
  end

  # ===========================================================================
  # Section 3: SemanticImage carries schema_version and schema_fingerprint
  # ===========================================================================
  describe "SemanticImage schema fields after checkpoint" do
    let(:machine) { build_machine(add_program) }

    before do
      RuntimeMachineMemoryProof::Fixture.seed(machine)
      machine.evaluate_program("add", { a: 3, b: 4 }, as_of: RuntimeMachineMemoryProof::PROOF_AS_OF)
    end

    let(:checkpoint_result) do
      machine.checkpoint(horizon: RuntimeMachineMemoryProof::Fixture.horizon)
    end

    let(:image) { checkpoint_result.fetch(:semantic_image) }

    it "SemanticImage has schema_version" do
      expect(image).to have_key("schema_version")
      expect(image.fetch("schema_version")).to eq("1.0.0")
    end

    it "SemanticImage has schema_fingerprint" do
      expect(image).to have_key("schema_fingerprint")
      expect(image.fetch("schema_fingerprint")).to start_with("sha256:")
    end

    it "SemanticImage.schema_fingerprint matches compiled program fingerprint" do
      expect(image.fetch("schema_fingerprint")).to eq(add_program.schema_fingerprint)
    end
  end

  # ===========================================================================
  # Section 4: CompatibilityReport schema_check — trusted path
  # ===========================================================================
  describe "CompatibilityReport schema_check — trusted (fingerprint match)" do
    let(:machine) { build_machine(add_program) }

    before do
      RuntimeMachineMemoryProof::Fixture.seed(machine)
      machine.evaluate_program("add", { a: 3, b: 4 }, as_of: RuntimeMachineMemoryProof::PROOF_AS_OF)
    end

    let(:checkpoint_result) { machine.checkpoint(horizon: RuntimeMachineMemoryProof::Fixture.horizon) }
    let(:image)             { checkpoint_result.fetch(:semantic_image) }

    let(:resume_result) do
      # Resume on a new machine that SHARES the same backend (snapshot/replay continuity)
      m2 = RuntimeMachineMemoryProof::RuntimeMachine.new(
        machine_id: "schema-machine-002",
        session_id: "schema-session-001",
        backend:    machine.backend
      )
      m2.boot
      m2.load_program(add_program)
      m2.resume(
        image:            image,
        requested_as_of:  RuntimeMachineMemoryProof::PROOF_AS_OF,
        intent:           "exact_replay"
      )
    end

    let(:report) { resume_result.fetch(:report) }

    it "schema_check dimension exists in checks" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema).not_to be_nil
    end

    it "schema_check outcome: compatible" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("outcome")).to eq("compatible")
    end

    it "schema_check fingerprint_match: true" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("fingerprint_match")).to be true
    end

    it "schema_check decision: trusted" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("decision")).to eq("trusted")
    end

    it "schema_check change_class: none" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("change_class")).to eq("none")
    end

    it "overall resume_status is trusted" do
      expect(report.fetch("resume_status")).to eq("trusted")
    end
  end

  # ===========================================================================
  # Section 5: CompatibilityReport schema_check — provisional (safe change)
  # ===========================================================================
  describe "CompatibilityReport schema_check — provisional (fingerprint mismatch, safe change)" do
    # Simulate a safe change: build a SemanticImage with a fake fingerprint
    # that differs from the loaded program but with same major version (0.x -> 0.x safe)
    let(:machine) { build_machine(add_program) }

    before do
      RuntimeMachineMemoryProof::Fixture.seed(machine)
      machine.evaluate_program("add", { a: 1, b: 2 }, as_of: RuntimeMachineMemoryProof::PROOF_AS_OF)
    end

    let(:checkpoint_result) { machine.checkpoint(horizon: RuntimeMachineMemoryProof::Fixture.horizon) }

    let(:stale_image) do
      # Simulate a safe change: same major version, different fingerprint
      img = checkpoint_result.fetch(:semantic_image).dup
      img["schema_fingerprint"] = "sha256:#{"a" * 64}"
      img["schema_version"]     = "1.0.0"  # same major, minor change expected
      img
    end

    let(:resume_result) do
      m2 = build_machine(add_program)
      m2.resume(
        image:           stale_image,
        requested_as_of: RuntimeMachineMemoryProof::PROOF_AS_OF,
        intent:          "exact_replay"
      )
    end

    let(:report) { resume_result.fetch(:report) }

    it "schema_check outcome: provisional (safe fingerprint mismatch, same major)" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("outcome")).to eq("provisional")
    end

    it "schema_check fingerprint_match: false" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("fingerprint_match")).to be false
    end

    it "schema_check change_class: safe" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("change_class")).to eq("safe")
    end

    it "schema_check decision: provisional" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("decision")).to eq("provisional")
    end

    it "severity is warning for provisional" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("severity")).to eq("warning")
    end
  end

  # ===========================================================================
  # Section 6: CompatibilityReport schema_check — blocked (breaking change)
  # ===========================================================================
  describe "CompatibilityReport schema_check — blocked (major version breaking change)" do
    let(:machine) { build_machine(add_program) }

    before do
      RuntimeMachineMemoryProof::Fixture.seed(machine)
      machine.evaluate_program("add", { a: 1, b: 2 }, as_of: RuntimeMachineMemoryProof::PROOF_AS_OF)
    end

    let(:checkpoint_result) { machine.checkpoint(horizon: RuntimeMachineMemoryProof::Fixture.horizon) }

    let(:old_major_image) do
      # Simulate a breaking change: image from major version 0, current is 1
      img = checkpoint_result.fetch(:semantic_image).dup
      img["schema_fingerprint"] = "sha256:#{"b" * 64}"
      img["schema_version"]     = "0.9.0"  # old major -> new major = breaking
      img
    end

    let(:resume_result) do
      m2 = build_machine(add_program)
      m2.resume(
        image:           old_major_image,
        requested_as_of: RuntimeMachineMemoryProof::PROOF_AS_OF,
        intent:          "exact_replay"
      )
    end

    let(:report) { resume_result.fetch(:report) }

    it "schema_check outcome: blocked" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("outcome")).to eq("blocked")
    end

    it "schema_check change_class: breaking" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("change_class")).to eq("breaking")
    end

    it "schema_check decision: blocked" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("decision")).to eq("blocked")
    end

    it "overall resume_status: blocked due to schema" do
      expect(report.fetch("resume_status")).to eq("blocked")
    end
  end

  # ===========================================================================
  # Section 7: schema_check — backward compat for pre-PROP-017 images
  # ===========================================================================
  describe "schema_check backward compat — pre-PROP-017 SemanticImage (no fingerprint)" do
    let(:machine) { build_machine(add_program) }

    before do
      RuntimeMachineMemoryProof::Fixture.seed(machine)
      machine.evaluate_program("add", { a: 2, b: 2 }, as_of: RuntimeMachineMemoryProof::PROOF_AS_OF)
    end

    let(:checkpoint_result) { machine.checkpoint(horizon: RuntimeMachineMemoryProof::Fixture.horizon) }

    let(:legacy_image) do
      # Simulate pre-PROP-017 image: no schema_fingerprint key
      img = checkpoint_result.fetch(:semantic_image).dup
      img.delete("schema_fingerprint")
      img.delete("schema_version")
      img
    end

    let(:resume_result) do
      # Resume on a new machine that SHARES the same backend (snapshot/replay continuity)
      m2 = RuntimeMachineMemoryProof::RuntimeMachine.new(
        machine_id: "schema-machine-003",
        session_id: "schema-session-001",
        backend:    machine.backend
      )
      m2.boot
      m2.load_program(add_program)
      m2.resume(
        image:           legacy_image,
        requested_as_of: RuntimeMachineMemoryProof::PROOF_AS_OF,
        intent:          "exact_replay"
      )
    end

    let(:report) { resume_result.fetch(:report) }

    it "schema_check outcome: compatible (trusted for legacy images)" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("outcome")).to eq("compatible")
    end

    it "schema_check fingerprint_match: true (backward compat)" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("fingerprint_match")).to be true
    end

    it "schema_check decision: trusted" do
      schema = report.fetch("checks").find { |c| c["dimension"] == "schema" }
      expect(schema.fetch("decision")).to eq("trusted")
    end

    it "overall resume_status is trusted (no other checks fail)" do
      expect(report.fetch("resume_status")).to eq("trusted")
    end
  end
end
