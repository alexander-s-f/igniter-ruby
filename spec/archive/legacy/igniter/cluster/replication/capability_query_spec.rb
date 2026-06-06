# frozen_string_literal: true

require "spec_helper"
require "igniter/cluster"

RSpec.describe Igniter::Cluster::Replication::CapabilityQuery do
  describe ".normalize" do
    it "turns arrays into all_of queries" do
      query = described_class.normalize(%i[local_llm container_runtime])
      expect(query.all_of).to eq(%i[container_runtime local_llm])
    end

    it "turns symbols into named single-capability queries" do
      query = described_class.normalize(:local_llm)
      expect(query.name).to eq(:local_llm)
      expect(query.all_of).to eq([:local_llm])
    end

    it "normalizes metadata order clauses" do
      query = described_class.normalize(
        all_of: [:local_llm],
        order_by: [
          { metadata: "trust.score", direction: "desc" },
          { metadata: %w[load avg1m], direction: :asc, nulls: "first" }
        ]
      )

      expect(query.order_by).to eq([
                                     { metadata: %i[trust score], direction: :desc, nulls: :last },
                                     { metadata: %i[load avg1m], direction: :asc, nulls: :first }
                                   ])
    end

    it "normalizes policy clauses to symbols" do
      query = described_class.normalize(
        all_of: [:local_llm],
        policy: {
          allows: ["system_read"],
          requires_approval: %w[shell_exec],
          permits: ["system_read"]
        }
      )

      expect(query.policy).to eq(
        allows: [:system_read],
        requires_approval: [:shell_exec],
        permits: [:system_read]
      )
    end

    it "normalizes decision clauses to symbols" do
      query = described_class.normalize(
        all_of: [:local_llm],
        decision: {
          mode: "approval_ok",
          actions: ["shell_exec"],
          risky: %w[filesystem_write]
        }
      )

      expect(query.decision).to eq(
        mode: :approval_ok,
        actions: [:shell_exec],
        risky: [:filesystem_write]
      )
    end

    it "normalizes trust clauses to symbols" do
      query = described_class.normalize(
        all_of: [:local_llm],
        trust: {
          identity: "trusted",
          attestation: "trusted",
          governance: "trusted"
        }
      )

      expect(query.trust).to eq(
        identity: :trusted,
        attestation: :trusted,
        governance: :trusted
      )
    end

    it "normalizes governance clauses to symbols" do
      query = described_class.normalize(
        all_of: [:local_llm],
        governance: {
          trust: "trusted",
          latest_type: "routing_plan_applied"
        }
      )

      expect(query.governance).to eq(
        trust: :trusted,
        latest_type: :routing_plan_applied
      )
    end
  end

  describe "#matches_profile?" do
    let(:profile) do
      Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        tags: %i[linux x86_64],
        metadata: {
          trust: { score: 0.92, tier: "gold" },
          health: { freshness_seconds: 12 },
          region: "eu-central"
        }
      )
    end

    it "matches a profile that satisfies all constraints" do
      query = described_class.new(all_of: %i[container_runtime local_llm], tags: [:linux])
      expect(query.matches_profile?(profile)).to be true
    end

    it "rejects a profile missing one required capability" do
      query = described_class.new(all_of: %i[container_runtime embedded])
      expect(query.matches_profile?(profile)).to be false
    end

    it "matches metadata using exact and operator predicates" do
      query = described_class.new(
        all_of: [:local_llm],
        metadata: {
          trust: { score: { min: 0.9 }, tier: { in: %w[gold platinum] } },
          health: { freshness_seconds: { max: 30 } },
          region: "eu-central"
        }
      )

      expect(query.matches_profile?(profile)).to be true
    end

    it "rejects metadata that does not satisfy the predicate" do
      query = described_class.new(
        all_of: [:local_llm],
        metadata: { trust: { score: { min: 0.99 } } }
      )

      expect(query.matches_profile?(profile)).to be false
    end

    it "matches against effective policy sets" do
      profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec filesystem_write],
            requires_approval: [:shell_exec],
            denies: [:filesystem_write]
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        policy: {
          permits: [:system_read],
          approvable: [:shell_exec],
          forbidden: [:filesystem_write]
        }
      )

      expect(query.matches_profile?(profile)).to be true
    end

    it "rejects a profile whose policy cannot auto-permit the requested action" do
      profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        policy: { permits: [:shell_exec] }
      )

      expect(query.matches_profile?(profile)).to be false
    end

    it "accepts approval-required execution when decision mode is approval_ok" do
      profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        decision: { mode: :approval_ok, actions: [:shell_exec] }
      )

      expect(query.matches_profile?(profile)).to be true
    end

    it "rejects approval-required execution when decision mode is auto_only" do
      profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          policy: {
            allows: %i[system_read shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        decision: { mode: :auto_only, actions: [:shell_exec] }
      )

      expect(query.matches_profile?(profile)).to be false
    end

    it "requires risky capabilities to be denied in deny_risky mode" do
      safe_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          policy: {
            allows: [:system_read],
            denies: [:filesystem_write]
          }
        }
      )

      risky_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          policy: {
            allows: %i[system_read filesystem_write]
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        decision: { mode: :deny_risky, actions: [:system_read], risky: [:filesystem_write] }
      )

      expect(query.matches_profile?(safe_profile)).to be true
      expect(query.matches_profile?(risky_profile)).to be false
    end

    it "matches explicit trust requirements for identity and attestation" do
      trusted_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          mesh_trust: { status: :trusted },
          mesh_capabilities: {
            trust: { status: :trusted },
            freshness_seconds: 12
          },
          mesh_governance: {
            trust: { status: :trusted },
            freshness_seconds: 8
          }
        }
      )

      unknown_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          mesh_trust: { status: :unknown },
          mesh_capabilities: {
            trust: { status: :unknown },
            freshness_seconds: 12
          },
          mesh_governance: {
            trust: { status: :unknown },
            freshness_seconds: 8
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        trust: {
          identity: :trusted,
          attestation: :trusted,
          attestation_freshness_seconds: { max: 30 },
          governance: :trusted,
          governance_freshness_seconds: { max: 30 }
        }
      )

      expect(query.matches_profile?(trusted_profile)).to be true
      expect(query.matches_profile?(unknown_profile)).to be false
    end

    it "matches explicit governance requirements for checkpoint health" do
      healthy_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          mesh_governance: {
            trust: { status: :trusted },
            freshness_seconds: 8,
            latest_type: :routing_plan_applied,
            blocked_events: 1,
            applied_events: 5
          }
        }
      )

      unhealthy_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[container_runtime local_llm ruby],
        metadata: {
          mesh_governance: {
            trust: { status: :trusted },
            freshness_seconds: 120,
            latest_type: :routing_plan_blocked,
            blocked_events: 4,
            applied_events: 1
          }
        }
      )

      query = described_class.new(
        all_of: [:local_llm],
        governance: {
          trust: :trusted,
          freshness_seconds: { max: 30 },
          latest_type: :routing_plan_applied,
          blocked_events: { max: 1 },
          applied_events: { min: 3 }
        }
      )

      expect(query.matches_profile?(healthy_profile)).to be true
      expect(query.matches_profile?(unhealthy_profile)).to be false
    end
  end

  describe "#compare_profiles" do
    let(:query) do
      described_class.new(
        all_of: [:local_llm],
        order_by: [
          { metadata: "trust.score", direction: :desc },
          { metadata: "load.avg1m", direction: :asc }
        ]
      )
    end

    let(:stronger_profile) do
      Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[local_llm container_runtime],
        metadata: {
          trust: { score: 0.98 },
          load: { avg1m: 0.40 }
        }
      )
    end

    let(:weaker_profile) do
      Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[local_llm container_runtime],
        metadata: {
          trust: { score: 0.91 },
          load: { avg1m: 0.10 }
        }
      )
    end

    let(:equal_trust_lower_load) do
      Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[local_llm container_runtime],
        metadata: {
          trust: { score: 0.98 },
          load: { avg1m: 0.15 }
        }
      )
    end

    it "prefers higher values for desc order clauses" do
      expect(query.compare_profiles(stronger_profile, weaker_profile)).to eq(-1)
      expect(query.compare_profiles(weaker_profile, stronger_profile)).to eq(1)
    end

    it "uses later clauses as tie-breakers" do
      expect(query.compare_profiles(equal_trust_lower_load, stronger_profile)).to eq(-1)
    end

    it "builds a stable ranking fingerprint" do
      expect(query.ranking_fingerprint(equal_trust_lower_load)).to eq([0.98, 0.15])
    end

    it "prefers automatic execution over approval-required when decisioned" do
      decision_query = described_class.new(
        all_of: [:local_llm],
        decision: { mode: :approval_ok, actions: [:shell_exec] }
      )

      automatic_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[local_llm container_runtime],
        metadata: {
          policy: {
            allows: [:shell_exec]
          }
        }
      )

      approval_profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: %i[local_llm container_runtime],
        metadata: {
          policy: {
            allows: [:shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )

      expect(decision_query.compare_profiles(automatic_profile, approval_profile)).to eq(-1)
    end
  end

  describe "#explain_profile" do
    it "describes which query dimensions rejected a profile" do
      profile = Igniter::Cluster::Replication::NodeProfile.new(
        capabilities: [:orders],
        tags: [:linux],
        metadata: {
          trust: { score: 0.7 },
          policy: {
            allows: %i[system_read shell_exec],
            requires_approval: [:shell_exec]
          }
        }
      )

      query = described_class.new(
        all_of: %i[orders gpu],
        tags: %i[linux cuda],
        metadata: { trust: { score: { min: 0.9 } } },
        trust: { identity: :trusted, attestation: :trusted },
        policy: { permits: [:shell_exec] },
        decision: { mode: :auto_only, actions: [:shell_exec] }
      )

      explanation = query.explain_profile(profile)

      expect(explanation).to include(
        matched: false,
        failed_dimensions: %i[capabilities tags metadata trust policy decision]
      )
      expect(explanation[:capabilities]).to include(missing_all_of: [:gpu])
      expect(explanation[:tags]).to include(missing: [:cuda])
      expect(explanation[:metadata]).to include(failed_paths: [%i[trust score]])
      expect(explanation[:trust]).to include(failed_keys: %i[identity attestation])
      expect(explanation[:policy]).to include(failed_keys: [:permits])
      expect(explanation[:decision]).to include(mode: :auto_only, outcome: :approval_required, matched: false)
    end
  end
end
