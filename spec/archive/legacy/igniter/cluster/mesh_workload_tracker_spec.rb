# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe "Igniter::Cluster Workload Signal Tracker (Phase 9)" do
  # ── WorkloadSignal ────────────────────────────────────────────────────────────

  describe Igniter::Cluster::Mesh::WorkloadSignal do
    it "builds a success signal" do
      s = described_class.build(peer_name: "node-a", capability: :database,
                                 success: true, duration_ms: 42.5)
      expect(s.peer_name).to eq("node-a")
      expect(s.capability).to eq(:database)
      expect(s.success).to be true
      expect(s.duration_ms).to eq(42.5)
      expect(s.error_class).to be_nil
    end

    it "builds a failure signal with error class" do
      error = RuntimeError.new("timeout")
      s = described_class.build(peer_name: "node-b", capability: :rag,
                                 success: false, error: error)
      expect(s).to be_failure
      expect(s.error_class).to eq("RuntimeError")
    end

    it "is frozen" do
      s = described_class.build(peer_name: "n", capability: :x, success: true)
      expect(s).to be_frozen
    end

    it "serializes to hash" do
      s = described_class.build(peer_name: "n", capability: :x, success: true, duration_ms: 10)
      h = s.to_h
      expect(h[:peer_name]).to eq("n")
      expect(h[:success]).to be true
      expect(h[:duration_ms]).to eq(10)
    end
  end

  # ── PeerCapacityReport ────────────────────────────────────────────────────────

  describe Igniter::Cluster::Mesh::PeerCapacityReport do
    def report(failures: 0, total: 10, avg_ms: nil, degraded: false, overloaded: false)
      Igniter::Cluster::Mesh::PeerCapacityReport.new(
        peer_name:       "node-a",
        total:           total,
        successes:       total - failures,
        failures:        failures,
        failure_rate:    total.zero? ? 0.0 : failures.to_f / total,
        avg_duration_ms: avg_ms,
        degraded:        degraded,
        overloaded:      overloaded,
        capabilities:    [:database]
      )
    end

    it "healthy? is true when not degraded and not overloaded" do
      expect(report).to be_healthy
    end

    it "healthy? is false when degraded" do
      expect(report(degraded: true)).not_to be_healthy
    end

    it "healthy? is false when overloaded" do
      expect(report(overloaded: true)).not_to be_healthy
    end

    it "serializes to hash" do
      r = report(failures: 3, total: 10, avg_ms: 120.5)
      h = r.to_h
      expect(h[:peer_name]).to eq("node-a")
      expect(h[:failure_rate]).to eq(0.3)
      expect(h[:avg_duration_ms]).to eq(120.5)
    end
  end

  # ── WorkloadTracker ───────────────────────────────────────────────────────────

  describe Igniter::Cluster::Mesh::WorkloadTracker do
    subject(:tracker) do
      described_class.new(window_size: 20, degraded_threshold: 0.3, overload_threshold_ms: 500)
    end

    describe "#record" do
      it "returns a WorkloadSignal" do
        sig = tracker.record("node-a", :database, success: true, duration_ms: 10)
        expect(sig).to be_a(Igniter::Cluster::Mesh::WorkloadSignal)
      end

      it "increments total signals" do
        3.times { tracker.record("node-a", :database, success: true) }
        expect(tracker.total_signals).to eq(3)
      end

      it "records without capability" do
        tracker.record("node-a", success: true)
        expect(tracker.total_signals).to eq(1)
      end
    end

    describe "#report_for" do
      before do
        5.times { tracker.record("node-a", :database, success: true,  duration_ms: 100) }
        3.times { tracker.record("node-a", :database, success: false, duration_ms: 800) }
      end

      it "returns a PeerCapacityReport" do
        expect(tracker.report_for("node-a")).to be_a(Igniter::Cluster::Mesh::PeerCapacityReport)
      end

      it "counts totals correctly" do
        r = tracker.report_for("node-a")
        expect(r.total).to eq(8)
        expect(r.successes).to eq(5)
        expect(r.failures).to eq(3)
      end

      it "computes failure_rate" do
        r = tracker.report_for("node-a")
        expect(r.failure_rate).to be_within(0.001).of(3.0 / 8)
      end

      it "computes avg_duration_ms" do
        r = tracker.report_for("node-a")
        # (5*100 + 3*800) / 8 = (500 + 2400) / 8 = 362.5
        expect(r.avg_duration_ms).to be_within(0.1).of(362.5)
      end

      it "degraded? is true when failure_rate >= threshold" do
        tracker2 = described_class.new(degraded_threshold: 0.3)
        7.times { tracker2.record("n", :x, success: false) }
        3.times { tracker2.record("n", :x, success: true) }
        expect(tracker2.report_for("n")).to be_degraded
      end

      it "degraded? is false when failure_rate < threshold" do
        # 3/8 = 0.375 >= 0.3 → degraded
        # use low-failure peer
        tracker2 = described_class.new(degraded_threshold: 0.5)
        5.times { tracker2.record("n", :x, success: true) }
        2.times { tracker2.record("n", :x, success: false) }
        expect(tracker2.report_for("n")).not_to be_degraded
      end

      it "overloaded? is true when avg_duration_ms >= threshold" do
        t = described_class.new(overload_threshold_ms: 400)
        3.times { t.record("n", :x, success: true, duration_ms: 600) }
        expect(t.report_for("n")).to be_overloaded
      end

      it "returns empty report for unknown peer" do
        r = tracker.report_for("ghost-node")
        expect(r.total).to eq(0)
        expect(r.failure_rate).to eq(0.0)
        expect(r).to be_healthy
      end
    end

    describe "#report_for_capability" do
      before do
        3.times { tracker.record("node-a", :database, success: true,  duration_ms: 50) }
        2.times { tracker.record("node-a", :rag,      success: false, duration_ms: 900) }
      end

      it "reports only for the given capability" do
        r = tracker.report_for_capability("node-a", :database)
        expect(r.total).to eq(3)
        expect(r.failure_rate).to eq(0.0)
      end

      it "separates capability stats" do
        r = tracker.report_for_capability("node-a", :rag)
        expect(r.total).to eq(2)
        expect(r.failure_rate).to eq(1.0)
      end
    end

    describe "#all_reports" do
      before do
        3.times { tracker.record("node-a", :database, success: true) }
        2.times { tracker.record("node-b", :rag,      success: false) }
      end

      it "returns a report for every seen peer" do
        reports = tracker.all_reports
        expect(reports.keys).to include("node-a", "node-b")
      end
    end

    describe "#degraded_peers" do
      before do
        5.times { tracker.record("healthy", :db, success: true) }
        7.times { tracker.record("sick", :db,     success: false) }
        3.times { tracker.record("sick", :db,     success: true) }
      end

      it "returns peers above threshold" do
        expect(tracker.degraded_peers).to include("sick")
      end

      it "excludes healthy peers" do
        expect(tracker.degraded_peers).not_to include("healthy")
      end

      it "respects custom threshold" do
        # sick has 7/10 = 0.7 failure rate
        expect(tracker.degraded_peers(threshold: 0.8)).to be_empty
      end
    end

    describe "#overloaded_peers" do
      before do
        3.times { tracker.record("fast",   :db, success: true, duration_ms: 100) }
        3.times { tracker.record("slow",   :db, success: true, duration_ms: 800) }
      end

      it "returns slow peers" do
        expect(tracker.overloaded_peers).to include("slow")
      end

      it "excludes fast peers" do
        expect(tracker.overloaded_peers).not_to include("fast")
      end
    end

    describe "sliding window" do
      it "drops oldest signals when window_size exceeded" do
        tracker2 = described_class.new(window_size: 5)
        # Fill with failures, then add successes to push failures out
        5.times { tracker2.record("n", :x, success: false) }
        5.times { tracker2.record("n", :x, success: true) }
        r = tracker2.report_for("n")
        expect(r.total).to eq(5)
        expect(r.failures).to eq(0)  # all failures pushed out
      end
    end

    describe "#reset_peer!" do
      it "clears signals for the specified peer only" do
        3.times { tracker.record("node-a", :db, success: false) }
        3.times { tracker.record("node-b", :db, success: true) }
        tracker.reset_peer!("node-a")
        expect(tracker.report_for("node-a").total).to eq(0)
        expect(tracker.report_for("node-b").total).to eq(3)
      end
    end

    describe "#reset!" do
      it "clears all signals" do
        3.times { tracker.record("node-a", :db, success: true) }
        tracker.reset!
        expect(tracker.total_signals).to eq(0)
      end
    end
  end

  # ── Mesh convenience methods ──────────────────────────────────────────────────

  describe "Mesh workload convenience methods" do
    before { Igniter::Cluster::Mesh.reset! }
    after  { Igniter::Cluster::Mesh.reset! }

    describe "Mesh.workload_tracker" do
      it "lazily creates a WorkloadTracker" do
        expect(Igniter::Cluster::Mesh.workload_tracker)
          .to be_a(Igniter::Cluster::Mesh::WorkloadTracker)
      end

      it "returns the same instance on repeated calls" do
        t1 = Igniter::Cluster::Mesh.workload_tracker
        t2 = Igniter::Cluster::Mesh.workload_tracker
        expect(t1).to equal(t2)
      end
    end

    describe "Mesh.record_workload" do
      it "returns a WorkloadSignal" do
        sig = Igniter::Cluster::Mesh.record_workload("node-a", :db, success: true, duration_ms: 50)
        expect(sig).to be_a(Igniter::Cluster::Mesh::WorkloadSignal)
      end

      it "accumulates in the workload_tracker" do
        3.times { Igniter::Cluster::Mesh.record_workload("node-a", :db, success: true) }
        expect(Igniter::Cluster::Mesh.workload_tracker.report_for("node-a").total).to eq(3)
      end

      it "records :peer_degraded in governance trail on first degradation" do
        # Push node-a into degraded state (failure_rate > 0.3)
        10.times { Igniter::Cluster::Mesh.record_workload("node-a", :db, success: false) }
        types = Igniter::Cluster::Mesh.config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:peer_degraded)
      end

      it "records :peer_recovered when peer recovers from degraded state" do
        t = described_class = Igniter::Cluster::Mesh.workload_tracker
        # Degrade first
        10.times { Igniter::Cluster::Mesh.record_workload("n", :x, success: false) }
        # Recover by filling window with successes
        t.instance_variable_get(:@window_size).times do
          Igniter::Cluster::Mesh.record_workload("n", :x, success: true)
        end
        types = Igniter::Cluster::Mesh.config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:peer_recovered)
      end

      it "records :peer_overloaded in governance trail when peer becomes overloaded" do
        t = Igniter::Cluster::Mesh.config.workload_tracker =
              Igniter::Cluster::Mesh::WorkloadTracker.new(overload_threshold_ms: 100)
        3.times { Igniter::Cluster::Mesh.record_workload("slow-node", :db, success: true, duration_ms: 500) }
        types = Igniter::Cluster::Mesh.config.governance_trail.events.map { |e| e[:type] }
        expect(types).to include(:peer_overloaded)
      end
    end

    describe "Mesh.repair_from_workload_signals!" do
      it "returns empty result when no degraded or overloaded peers" do
        3.times { Igniter::Cluster::Mesh.record_workload("healthy", :db, success: true) }
        result = Igniter::Cluster::Mesh.repair_from_workload_signals!
        expect(result[:degraded]).to be_empty
        expect(result[:plans]).to be_empty
      end

      it "identifies degraded peers" do
        10.times { Igniter::Cluster::Mesh.record_workload("sick-peer", :db, success: false) }
        result = Igniter::Cluster::Mesh.repair_from_workload_signals!
        expect(result[:degraded]).to include("sick-peer")
      end

      it "generates repair plans for degraded peers registered in the mesh" do
        Igniter::Cluster::Mesh.configure do |c|
          c.add_peer "sick-peer", url: "http://sick:4567", capabilities: [:database]
        end
        10.times { Igniter::Cluster::Mesh.record_workload("sick-peer", :db, success: false) }
        result = Igniter::Cluster::Mesh.repair_from_workload_signals!
        expect(result[:plans]).not_to be_empty
        actions = result[:plans].map { |p| p[:action] }
        expect(actions).to include(:refresh_capabilities)
      end

      it "skips peers not in the registry (no observation)" do
        10.times { Igniter::Cluster::Mesh.record_workload("unknown-peer", :db, success: false) }
        result = Igniter::Cluster::Mesh.repair_from_workload_signals!
        expect(result[:plans]).to be_empty
      end

      it "accepts custom degraded_threshold" do
        5.times { Igniter::Cluster::Mesh.record_workload("borderline", :db, success: false) }
        5.times { Igniter::Cluster::Mesh.record_workload("borderline", :db, success: true) }
        # 0.5 failure rate
        expect(Igniter::Cluster::Mesh.repair_from_workload_signals!(degraded_threshold: 0.6)[:degraded])
          .not_to include("borderline")
        expect(Igniter::Cluster::Mesh.repair_from_workload_signals!(degraded_threshold: 0.4)[:degraded])
          .to include("borderline")
      end
    end
  end
end
