# frozen_string_literal: true

require "spec_helper"
require_relative "../../igniter-lang/experiments/runtime_machine_memory_proof/compiled_program"

RSpec.describe "Add .igapp/ Devkit Fixture — End-to-End" do
  IGAPP_PATH = File.expand_path(
    "../../igniter-lang/fixtures/add.igapp",
    __dir__
  ).freeze

  AS_OF_BEFORE_EVAL = "2026-05-05T09:59:00Z"
  AS_OF_EVAL        = "2026-05-05T10:01:00Z"

  subject(:machine) do
    backend = RuntimeMachineMemoryProof::MemoryTBackend.new
    m = RuntimeMachineMemoryProof::RuntimeMachine.new(
      machine_id:  "test-machine-001",
      session_id:  "session-test-001",
      backend:     backend
    )
    m.boot
    m
  end

  let(:backend) { machine.backend }

  let(:program) do
    RuntimeMachineMemoryProof::CompiledProgram.load_igapp(IGAPP_PATH)
  end

  # ---------------------------------------------------------------------------
  # FIXTURE-003: Load CORE contracts
  # ---------------------------------------------------------------------------
  describe "Step 1: Load hand-authored artifact (FIXTURE-003)" do
    before { machine.load_program(program) }

    it "returns status: loaded" do
      result = machine.load_program(program)
      expect(result.fetch(:status)).to eq("loaded")
    end

    it "emits a descriptor_observation for Add" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      desc = obs.find { |p| p.kind == "descriptor_observation" && p.subject == "contract://add" }
      expect(desc).not_to be_nil
    end

    it "descriptor_observation carries artifact_hash (provenance anchor)" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      desc = obs.find { |p| p.kind == "descriptor_observation" }
      expect(desc.payload["artifact_hash"]).to eq(program.artifact_hash)
    end

    it "emits ClassifiedAST observation" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      ast = obs.find { |p| p.kind == "platform_observation" && p.subject.start_with?("classified://") }
      expect(ast).not_to be_nil
      expect(ast.payload["fragment_class"]).to eq("core")
      expect(ast.payload["oof_count"]).to eq(0)
    end

    it "emits LoadReceipt with contracts_loaded: 1" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      receipt = obs.find { |p| p.kind == "platform_observation" && p.subject.start_with?("load://") }
      expect(receipt).not_to be_nil
      expect(receipt.payload["contracts_loaded"]).to eq(1)
      expect(receipt.payload["status"]).to eq("loaded")
    end

    it "all observations carry observed_under links" do
      # After boot + load, all obs should link back to axiom + runtime
      obs = backend.entries.map { |e| e.fetch(:packet) }
      # descriptor_obs and later obs carry evidence_links
      desc = obs.find { |p| p.kind == "descriptor_observation" }
      link_rels = desc.links.map { |l| l.fetch("rel") }
      expect(link_rels).to include("observed_under")
      expect(link_rels).to include("produced_in")
    end
  end

  # ---------------------------------------------------------------------------
  # FIXTURE-005: Evaluate Add(3, 4)
  # ---------------------------------------------------------------------------
  describe "Step 2: Evaluate Add(3, 4) (FIXTURE-005)" do
    before do
      machine.load_program(program)
      @eval_result = machine.evaluate_program("add", { a: 3, b: 4 }, as_of: AS_OF_EVAL)
    end

    it "returns status: ok" do
      expect(@eval_result.fetch(:status)).to eq("ok")
    end

    it "computes sum = 7" do
      expect(@eval_result.fetch(:outputs)).to eq({ "sum" => 7 })
    end

    it "emits value_observation with payload 7" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      val = obs.find { |p| p.kind == "value_observation" && p.subject == "contract://add/sum" }
      expect(val).not_to be_nil
      expect(val.payload).to eq(7)
    end

    it "value_observation temporal.as_of matches evaluation time" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      val = obs.find { |p| p.kind == "value_observation" }
      expect(val.temporal.fetch("as_of")).to eq(AS_OF_EVAL)
    end

    it "emits EvaluationReceipt with status: ok" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      receipt = obs.find { |p| p.kind == "platform_observation" && p.subject.start_with?("eval://") }
      expect(receipt).not_to be_nil
      expect(receipt.payload["status"]).to eq("ok")
    end

    # Reproducibility: same inputs + same Tt -> same content_hash
    it "produces the same content_hash for the same inputs and as_of" do
      obs1 = backend.entries.map { |e| e.fetch(:packet) }
      val1 = obs1.find { |p| p.kind == "value_observation" }

      # Second machine, same inputs, same as_of
      backend2 = RuntimeMachineMemoryProof::MemoryTBackend.new
      m2 = RuntimeMachineMemoryProof::RuntimeMachine.new(
        machine_id: "test-machine-002",
        session_id: "session-test-002",
        backend:    backend2
      )
      m2.boot
      m2.load_program(program)
      m2.evaluate_program("add", { a: 3, b: 4 }, as_of: AS_OF_EVAL)

      obs2 = backend2.entries.map { |e| e.fetch(:packet) }
      val2 = obs2.find { |p| p.kind == "value_observation" }

      expect(val1.payload_hash).to eq(val2.payload_hash)
    end
  end

  # ---------------------------------------------------------------------------
  # FIXTURE-006: Missing TemporalCtx -> OOF
  # ---------------------------------------------------------------------------
  describe "Step 3: Missing as_of rejects evaluation (FIXTURE-006)" do
    before { machine.load_program(program) }

    it "returns status: blocked when as_of is nil" do
      result = machine.evaluate_program("add", { a: 1, b: 2 }, as_of: nil)
      expect(result.fetch(:status)).to eq("blocked")
    end

    it "emits a failure_observation with reason_code temporal.as_of_missing" do
      machine.evaluate_program("add", { a: 1, b: 2 }, as_of: nil)
      obs = backend.entries.map { |e| e.fetch(:packet) }
      failure = obs.find { |p| p.kind == "failure_observation" }
      expect(failure).not_to be_nil
      expect(failure.payload["reason_code"]).to eq("temporal.as_of_missing")
    end

    it "does not emit a value_observation after failed evaluation" do
      machine.evaluate_program("add", { a: 1, b: 2 }, as_of: nil)
      obs = backend.entries.map { |e| e.fetch(:packet) }
      value_obs = obs.select { |p| p.kind == "value_observation" }
      expect(value_obs).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # FIXTURE-010: Temporal read isolation
  # ---------------------------------------------------------------------------
  describe "Step 4: Temporal read isolation (FIXTURE-010)" do
    before do
      machine.load_program(program)
      machine.evaluate_program("add", { a: 3, b: 4 }, as_of: AS_OF_EVAL)
    end

    it "value_observation temporal.as_of is exactly the evaluation as_of" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      val = obs.find { |p| p.kind == "value_observation" }
      # as_of must be exactly what we passed — no ambient clock
      expect(val.temporal.fetch("as_of")).to eq(AS_OF_EVAL)
      expect(val.temporal.fetch("as_of")).not_to eq(AS_OF_BEFORE_EVAL)
    end

    it "a second evaluation with different as_of produces a distinct observation id" do
      as_of_later = "2026-05-05T10:02:00Z"
      machine.evaluate_program("add", { a: 3, b: 4 }, as_of: as_of_later)

      obs = backend.entries.map { |e| e.fetch(:packet) }
      value_obs = obs.select { |p| p.kind == "value_observation" }
      expect(value_obs.size).to eq(2)
      # Different temporal ctx -> different obs.id (temporal is part of identity_material)
      expect(value_obs[0].id).not_to eq(value_obs[1].id)
      # The payload itself (7) is the same, so payload_hash is the same
      expect(value_obs[0].payload_hash).to eq(value_obs[1].payload_hash)
      # But the temporal.as_of differs
      expect(value_obs[0].temporal.fetch("as_of")).not_to eq(value_obs[1].temporal.fetch("as_of"))
    end
  end

  # ---------------------------------------------------------------------------
  # FIXTURE-007: Checkpoint sequence
  # ---------------------------------------------------------------------------
  describe "Step 5: Checkpoint sequence (FIXTURE-007)" do
    before do
      machine.load_program(program)
      machine.evaluate_program("add", { a: 3, b: 4 }, as_of: AS_OF_EVAL)
      @checkpoint_result = machine.checkpoint(horizon: { as_of: AS_OF_EVAL })
    end

    it "checkpoint returns status: ok" do
      expect(@checkpoint_result.fetch(:status)).to eq("ok")
    end

    it "emits a SemanticImage platform_observation" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      image = obs.find { |p| p.kind == "platform_observation" && p.subject.start_with?("semantic-image/") }
      expect(image).not_to be_nil
    end

    it "SemanticImage seq_id is less than last_seq (emitted before end)" do
      obs = backend.entries
      image_entry = obs.find { |e| e.fetch(:packet).subject.start_with?("semantic-image/") }
      last_seq = backend.last_seq
      expect(image_entry.fetch(:seq_id)).to be < last_seq
    end

    it "SemanticImage contains session_id and observation_count" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      image = obs.find { |p| p.subject.start_with?("semantic-image/") }
      payload = image.payload
      expect(payload["session_id"]).to eq("session-test-001")
      expect(payload["observation_count"]).to be > 0
    end

    it "SemanticImage content_hash is stable (deterministic)" do
      obs = backend.entries.map { |e| e.fetch(:packet) }
      image = obs.find { |p| p.subject.start_with?("semantic-image/") }
      # content_hash must equal hash of image_base fields
      expect(image.payload_hash).not_to be_nil
      # Recompute check: payload_hash is Canonical.hash(payload)
      expected = RuntimeMachineMemoryProof::Canonical.hash(image.payload)
      expect(image.payload_hash).to eq(expected)
    end
  end

  # ---------------------------------------------------------------------------
  # FIXTURE-008: Resume trusted
  # ---------------------------------------------------------------------------
  describe "Step 6: Resume trusted (FIXTURE-008)" do
    let(:session_a_image) do
      machine.load_program(program)
      machine.evaluate_program("add", { a: 3, b: 4 }, as_of: AS_OF_EVAL)
      result = machine.checkpoint(horizon: { as_of: AS_OF_EVAL })
      result.fetch(:semantic_image)
    end

    it "resumes as trusted when runtime and backend match" do
      # Build session B with same backend (same memory harness)
      session_b = RuntimeMachineMemoryProof::RuntimeMachine.new(
        machine_id: "test-machine-002",
        session_id: "session-test-002",
        backend:    backend
      )
      session_b.boot
      session_b.load_program(program)

      result = session_b.resume(
        image:            session_a_image,
        requested_as_of:  AS_OF_EVAL,
        intent:           "exact_replay"
      )

      expect(result.fetch(:status)).to eq("trusted")
    end
  end

  # ---------------------------------------------------------------------------
  # Artifact validation checklist (PROP-012)
  # ---------------------------------------------------------------------------
  describe "Artifact validation checklist (PROP-012)" do
    it "fragment_class is core" do
      expect(program.fragment_class).to eq("core")
    end

    it "oof_count is 0" do
      expect(program.oof_count).to eq(0)
    end

    it "diagnostics is empty" do
      expect(program.diagnostics.fetch("diagnostics", [])).to be_empty
    end

    it "required_caps is empty" do
      expect(program.required_caps).to be_empty
    end

    it "effect_kinds is empty" do
      expect(program.effect_kinds).to be_empty
    end

    it "dependency_graph has no cycles (DAG)" do
      graph = program.dependency_graph
      nodes = graph.fetch("nodes", [])
      edges = graph.fetch("edges", [])
      # Build adjacency list and check for cycles via DFS
      adj = Hash.new { |h, k| h[k] = [] }
      edges.each { |e| adj[e.fetch("from")] << e.fetch("to") }

      visited = {}
      in_stack = {}
      has_cycle = false

      dfs = lambda do |node|
        visited[node] = true
        in_stack[node] = true
        adj[node].each do |neighbor|
          if !visited[neighbor]
            dfs.call(neighbor)
          elsif in_stack[neighbor]
            has_cycle = true
          end
        end
        in_stack[node] = false
      end

      nodes.each { |n| dfs.call(n) unless visited[n] }
      expect(has_cycle).to be false
    end

    it "required_tbackend_caps.read_as_of is true" do
      expect(program.required_tbackend_caps.fetch("read_as_of")).to be true
    end

    it "program_id is present and non-empty" do
      expect(program.program_id).not_to be_nil
      expect(program.program_id).not_to be_empty
    end

    it "artifact_hash is present and SHA-256 prefixed" do
      expect(program.artifact_hash).to match(/\Asha256:/)
    end
  end
end
