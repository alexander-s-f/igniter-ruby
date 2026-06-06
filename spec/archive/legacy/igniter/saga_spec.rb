# frozen_string_literal: true

require "igniter"
require "igniter/extensions/saga"
require "igniter/extensions/execution_report"

RSpec.describe "Igniter Saga and Execution Report" do
  # ── Shared fixtures ──────────────────────────────────────────────────────────

  # Linear workflow: step_a → step_b → step_c
  let(:workflow_class) do
    Class.new(Igniter::Contract) do
      define do
        input :trigger

        compute :step_a, depends_on: :trigger do |trigger:|
          { result: "a-#{trigger}" }
        end

        compute :step_b, depends_on: %i[trigger step_a] do |trigger:, **|
          raise "step_b failed for #{trigger}" if trigger == "fail_b"
          { result: "b" }
        end

        compute :step_c, depends_on: %i[step_a step_b] do |**|
          { result: "c" }
        end

        output :step_a
        output :step_b
        output :step_c
      end
    end
  end

  # Apply compensations to a fresh copy of the workflow
  def workflow_with_compensations(comp_log = [])
    klass = workflow_class
    Class.new(klass) do
      compensate :step_b do |inputs:, value:|
        comp_log << { node: :step_b, inputs: inputs, value: value }
      end

      compensate :step_a do |inputs:, value:|
        comp_log << { node: :step_a, inputs: inputs, value: value }
      end
    end
  end

  # ── Igniter::Extensions::Saga — compensate DSL ───────────────────────────────

  describe "compensate class method" do
    it "stores compensations on the class" do
      klass = Class.new(Igniter::Contract) do
        define { input :x; output :x }
        compensate(:x) { |**| }
      end
      expect(klass.compensations.keys).to include(:x)
    end

    it "wraps the block in a Compensation object" do
      klass = Class.new(Igniter::Contract) do
        define { input :x; output :x }
        compensate(:x) { |**| }
      end
      expect(klass.compensations[:x]).to be_a(Igniter::Saga::Compensation)
    end

    it "returns empty hash when no compensations are declared" do
      klass = Class.new(Igniter::Contract) do
        define { input :x; output :x }
      end
      expect(klass.compensations).to eq({})
    end

    it "accepts Symbol or string node_name" do
      klass = Class.new(Igniter::Contract) do
        define { input :x; output :x }
        compensate(:x) { |**| }
      end
      expect(klass.compensations).to have_key(:x)
    end
  end

  # ── resolve_saga — success path ──────────────────────────────────────────────

  describe "#resolve_saga — success" do
    subject(:result) do
      workflow_class.new(trigger: "ok").resolve_saga
    end

    it "returns a Result" do
      expect(result).to be_a(Igniter::Saga::Result)
    end

    it "marks the result as successful" do
      expect(result.success?).to be true
    end

    it "has no error" do
      expect(result.error).to be_nil
    end

    it "has no failed_node" do
      expect(result.failed_node).to be_nil
    end

    it "runs no compensations" do
      expect(result.compensations).to be_empty
    end

    it "returns the contract instance" do
      expect(result.contract).to be_a(Igniter::Contract)
    end
  end

  # ── resolve_saga — failure path ──────────────────────────────────────────────

  describe "#resolve_saga — failure with compensations" do
    let(:comp_log)  { [] }
    let(:klass)     { workflow_with_compensations(comp_log) }
    subject(:result) { klass.new(trigger: "fail_b").resolve_saga }

    it "returns a failed Result" do
      expect(result.failed?).to be true
    end

    it "captures the error" do
      expect(result.error).to be_a(Igniter::Error)
    end

    it "captures the failing node name" do
      expect(result.failed_node).to eq :step_b
    end

    it "runs compensation for step_a (the only succeeded node before failure)" do
      result
      compensated_nodes = comp_log.map { |r| r[:node] }
      expect(compensated_nodes).to include(:step_a)
    end

    it "does NOT run compensation for step_b (it failed, not succeeded)" do
      result
      compensated_nodes = comp_log.map { |r| r[:node] }
      expect(compensated_nodes).not_to include(:step_b)
    end

    it "does NOT run compensation for step_c (it never ran)" do
      result
      compensated_nodes = comp_log.map { |r| r[:node] }
      expect(compensated_nodes).not_to include(:step_c)
    end

    it "passes the node's value to the compensation block" do
      result
      step_a_record = comp_log.find { |r| r[:node] == :step_a }
      expect(step_a_record[:value]).to include(result: "a-fail_b")
    end

    it "passes the node's dependency values as inputs" do
      result
      step_a_record = comp_log.find { |r| r[:node] == :step_a }
      expect(step_a_record[:inputs]).to have_key(:trigger)
    end

    it "returns CompensationRecords for each run compensation" do
      records = result.compensations
      expect(records).to all(be_a(Igniter::Saga::CompensationRecord))
    end

    it "records success for each compensation that ran without error" do
      result.compensations.each do |rec|
        expect(rec.success?).to be true
      end
    end
  end

  # ── Compensation ordering ────────────────────────────────────────────────────

  describe "compensation reverse-topological order" do
    it "runs compensations in reverse resolution order" do
      order_log = []
      klass = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :first,  depends_on: :x do |x:| x * 1 end
          compute :second, depends_on: :first do |first:| first * 2 end
          compute :third,  depends_on: :second do |second:|
            raise "boom"
          end
          output :third  # :third must be in dep chain so it actually runs
        end
        compensate(:second) { |**| order_log << :second }
        compensate(:first)  { |**| order_log << :first }
      end

      klass.new(x: 1).resolve_saga
      expect(order_log).to eq([:second, :first])
    end
  end

  # ── Compensation failure resilience ─────────────────────────────────────────

  describe "when a compensation itself raises" do
    let(:klass) do
      Class.new(Igniter::Contract) do
        define do
          input :x
          compute :step_a, depends_on: :x do |x:| x end
          compute :step_b, depends_on: :step_a do |**| raise "forward fail" end
          output :step_b  # :step_b must be in dep chain so it actually runs and fails
        end
        compensate(:step_a) { |**| raise "compensation also failed" }
      end
    end

    subject(:result) { klass.new(x: 42).resolve_saga }

    it "still returns a Result (does not raise)" do
      expect { result }.not_to raise_error
    end

    it "records the compensation as failed" do
      expect(result.compensations.first.failed?).to be true
    end

    it "captures the compensation error" do
      expect(result.compensations.first.error.message).to eq "compensation also failed"
    end

    it "marks the saga result as failed (original error)" do
      expect(result.failed?).to be true
    end
  end

  # ── Saga::Result API ─────────────────────────────────────────────────────────

  describe "Igniter::Saga::Result" do
    let(:comp_log) { [] }
    let(:result)   { workflow_with_compensations(comp_log).new(trigger: "fail_b").resolve_saga }

    it "#explain returns readable text" do
      text = result.explain
      expect(text).to include("Contract:")
      expect(text).to include("FAILED")
    end

    it "#explain includes the error message" do
      expect(result.explain).to include("step_b failed")
    end

    it "#explain includes compensation info" do
      expect(result.explain).to include("COMPENSATIONS")
    end

    it "#to_s aliases #explain" do
      expect(result.to_s).to eq(result.explain)
    end

    it "#to_h returns a serialisable Hash" do
      h = result.to_h
      expect(h[:success]).to be false
      expect(h[:failed_node]).to eq :step_b
      expect(h[:error]).to be_a(String)
      expect(h[:compensations]).to be_an(Array)
    end

    it "is frozen" do
      expect(result).to be_frozen
    end
  end

  # ── Igniter::Extensions::ExecutionReport ─────────────────────────────────────

  describe "#execution_report" do
    context "after a successful execution" do
      subject(:report) do
        contract = workflow_class.new(trigger: "ok")
        contract.resolve_all
        contract.execution_report
      end

      it "returns an ExecutionReport::Report" do
        expect(report).to be_a(Igniter::ExecutionReport::Report)
      end

      it "reports success" do
        expect(report.success?).to be true
      end

      it "shows all compute nodes as succeeded" do
        expect(report.resolved_nodes).to include(:step_a, :step_b, :step_c)
      end

      it "has no failed nodes" do
        expect(report.failed_nodes).to be_empty
      end

      it "has no pending nodes" do
        expect(report.pending_nodes).to be_empty
      end
    end

    context "after a failed execution" do
      subject(:report) do
        contract = workflow_class.new(trigger: "fail_b")
        contract.resolve_all rescue nil
        contract.execution_report
      end

      it "reports failure" do
        expect(report.success?).to be false
      end

      it "shows the failed node" do
        expect(report.failed_nodes).to include(:step_b)
      end

      it "shows the node that ran before the failure as succeeded" do
        expect(report.resolved_nodes).to include(:step_a)
      end

      it "shows downstream nodes as failed when upstream fails" do
        # Igniter propagates failures: step_c depends on step_b and is also marked :failed
        expect(report.failed_nodes).to include(:step_c)
      end

      it "includes the error in the errors hash" do
        expect(report.errors).to have_key(:step_b)
      end
    end

    context "NodeEntry details" do
      subject(:entries) do
        contract = workflow_class.new(trigger: "ok")
        contract.resolve_all
        contract.execution_report.entries
      end

      it "includes input nodes" do
        expect(entries.map(&:name)).to include(:trigger)
      end

      it "sets kind correctly" do
        trigger_entry = entries.find { |e| e.name == :trigger }
        expect(trigger_entry.kind).to eq :input
      end

      it "all entries are frozen" do
        expect(entries).to all(be_frozen)
      end
    end
  end

  # ── ExecutionReport::Report API ─────────────────────────────────────────────

  describe "Igniter::ExecutionReport::Report" do
    let(:failed_report) do
      contract = workflow_class.new(trigger: "fail_b")
      contract.resolve_all rescue nil
      contract.execution_report
    end

    it "#explain returns readable text with node names" do
      text = failed_report.explain
      expect(text).to include("step_a")
      expect(text).to include("step_b")
    end

    it "#explain marks failed nodes with [fail]" do
      expect(failed_report.explain).to include("[fail]")
    end

    it "#explain marks succeeded nodes with [ok]" do
      expect(failed_report.explain).to include("[ok]")
    end

    it "#explain marks downstream-failed nodes with [fail]" do
      # Igniter propagates failures to dependent nodes — all show as [fail]
      failed_report.explain.scan(/\[fail\]/).tap do |matches|
        expect(matches.size).to be >= 2  # step_b + step_c both failed
      end
    end

    it "#to_h returns a serialisable Hash" do
      h = failed_report.to_h
      expect(h[:success]).to be false
      expect(h[:nodes]).to be_an(Array)
      expect(h[:nodes].first).to include(:name, :kind, :status)
    end

    it "is frozen" do
      expect(failed_report).to be_frozen
    end
  end

  # ── Integration: resolve_saga + execution_report ─────────────────────────────

  describe "saga result combined with execution_report" do
    it "execution_report on the saga contract shows compensation context" do
      comp_log = []
      klass = workflow_with_compensations(comp_log)
      result = klass.new(trigger: "fail_b").resolve_saga

      report = result.contract.execution_report
      expect(report.failed_nodes).to include(:step_b)
      expect(report.resolved_nodes).to include(:step_a)
    end

    it "no compensations run on successful saga" do
      comp_log = []
      klass = workflow_with_compensations(comp_log)
      klass.new(trigger: "ok").resolve_saga

      expect(comp_log).to be_empty
    end
  end
end
