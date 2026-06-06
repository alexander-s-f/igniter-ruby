# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Cluster::Environment do
  def build_mesh_transport
    lambda do |request:|
      if request.is_a?(Igniter::Cluster::MeshExecutionRequest)
        Igniter::Cluster::MeshExecutionResponse.new(
          status: :completed,
          metadata: {
            accepted_by: request.metadata.fetch(:peer).fetch(:name),
            trace_id: request.trace_id
          },
          explanation: Igniter::Cluster::DecisionExplanation.new(
            code: :mesh_peer_accept,
            message: "mesh peer accepted #{request.plan_kind}",
            metadata: { peer: request.metadata.fetch(:peer).fetch(:name) }
          )
        )
      else
        build_peer_transport(nil).call(request:)
      end
    end
  end

  def build_failing_mesh_transport
    lambda do |request:|
      if request.is_a?(Igniter::Cluster::MeshExecutionRequest)
        Igniter::Cluster::MeshExecutionResponse.new(
          status: :failed,
          metadata: {
            rejected_by: request.metadata.fetch(:peer).fetch(:name),
            trace_id: request.trace_id
          },
          explanation: Igniter::Cluster::DecisionExplanation.new(
            code: :mesh_peer_reject,
            message: "mesh peer rejected #{request.plan_kind}",
            metadata: { peer: request.metadata.fetch(:peer).fetch(:name) }
          )
        )
      else
        build_peer_transport(nil).call(request:)
      end
    end
  end

  class DynamicMembershipSource
    def feed
      Igniter::Cluster::MembershipFeed.new(
        name: :dynamic_membership_source,
        discovery_feed: Igniter::Cluster::DiscoveryFeed.new(
          name: :dynamic_discovery_source,
          metadata: {
            strategy: :scripted
          }
        ),
        metadata: {
          first_peers: @first_peers.dup,
          second_peers: @second_peers.dup
        }
      )
    end

    def to_h
      feed.to_h
    end

    def initialize(first_peers:, second_peers:)
      @first_peers = Array(first_peers).map(&:to_sym)
      @second_peers = Array(second_peers).map(&:to_sym)
      @calls = 0
    end

    def call(environment:, allow_degraded:, metadata: {}, previous_membership: nil)
      @calls += 1
      selected_names = @calls == 1 ? @first_peers : @second_peers
      selected_peers = environment.peers.select { |peer| selected_names.include?(peer.name) }
      version = @calls
      joined_names = selected_names - Array(previous_membership&.peers).map(&:name)
      events = joined_names.map do |peer_name|
        Igniter::Cluster::MeshMembershipEvent.new(
          version: version,
          type: :peer_joined,
          peer_name: peer_name,
          metadata: { source: :dynamic_spec }
        )
      end
      Igniter::Cluster::MeshMembership.new(
        peers: selected_peers,
        allow_degraded: allow_degraded,
        metadata: metadata.merge(source: :dynamic_spec),
        version: version,
        epoch: "dynamic/#{version}",
        events: events,
        source: :dynamic_spec,
        snapshot_id: "dynamic_spec/#{version}",
        previous_snapshot_id: previous_membership&.snapshot_id,
        lineage: Array(previous_membership&.lineage) + ["dynamic_spec/#{version}"],
        feed: feed
      )
    end
  end

  def build_peer_transport(contracts_profile)
    lambda do |request:|
      result =
        case request.kind
        when :compose
          Igniter::Contracts.execute(
            request.compiled_graph,
            inputs: request.inputs,
            profile: contracts_profile
          )
        when :collection
          Igniter::Extensions::Contracts::CollectionPack::LocalInvoker.call(
            invocation: Igniter::Extensions::Contracts::CollectionPack::Invocation.new(
              operation: Igniter::Contracts::Operation.new(
                kind: :collection,
                name: request.operation_name,
                attributes: {}
              ),
              items: request.items,
              inputs: request.inputs,
              compiled_graph: request.compiled_graph,
              profile: contracts_profile,
              key_name: request.key_name,
              window: request.window
            )
          )
        else
          raise "unsupported request kind #{request.kind.inspect}"
        end

      Igniter::Application::TransportResponse.new(
        result: result,
        metadata: { adapter: :in_memory_peer }
      )
    end
  end

  it "routes compose sessions through capability-aware peers" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .finalize
    cluster = described_class.new(profile: cluster)

    cluster.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      transport: build_peer_transport(cluster.application.profile.contracts_profile),
      metadata: { owner: :mesh },
      roles: %i[pricing compute],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a
    )

    result = cluster.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: cluster.compose_invoker(
                capabilities: [:pricing],
                namespace: :mesh,
                metadata: { source: :cluster_spec }
              ) do
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      output :pricing_total
    end

    entry = cluster.application.fetch_session("mesh/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(120.0)
    expect(entry.payload.fetch(:transport)).to include(adapter: :in_memory_peer)
    expect(entry.payload.fetch(:transport).dig(:cluster, :query, :required_capabilities)).to eq([:pricing])
    expect(entry.payload.fetch(:transport).dig(:cluster, :query, :required_capability_definitions)).to contain_exactly(
      include(name: :pricing, traits: [:financial], labels: { domain: "commerce" })
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :peer)).to eq(:pricing_node)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :mode)).to eq(:capability)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :explanation)).to include(
      code: :capability_route,
      message: "capability route to pricing_node"
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :metadata, :selected_peer_profile)).to include(
      name: :pricing_node,
      roles: %i[compute pricing],
      topology: include(
        region: "eu_west",
        zone: "eu_west_1a",
        labels: { tier: "gold" }
      ),
      labels: { tier: "gold" },
      region: "eu_west",
      zone: "eu_west_1a",
      metadata: { owner: :mesh }
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :metadata, :selected_peer_profile,
                                               :capability_definitions))
      .to contain_exactly(include(name: :pricing, traits: [:financial], labels: { domain: "commerce" }))
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :metadata, :selected_peer_view)).to include(
      peer: :pricing_node,
      included: true,
      capability_match: true,
      topology_match: true,
      preferred_peer_match: true,
      profile: include(name: :pricing_node, roles: %i[compute pricing])
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :metadata, :membership_projection)).to include(
      candidate_names: [:pricing_node],
      candidate_views: include(include(peer: :pricing_node, included: true)),
      stages: include(
        include(name: :source),
        include(name: :preferred_peer),
        include(name: :topology),
        include(name: :capabilities),
        include(name: :candidate_limit)
      )
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :metadata, :route_projection_report)).to include(
      mode: :capability,
      status: :resolved,
      candidate_names: [:pricing_node],
      selected_peer_view: include(peer: :pricing_node, included: true)
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :admission, :reason)).to include(
      code: :permissive_accept
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :admission, :metadata, :peer_view)).to include(
      peer: :pricing_node,
      included: true,
      capability_match: true
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :admission, :metadata, :peer_profile)).to include(
      name: :pricing_node,
      roles: %i[compute pricing]
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :projection_report)).to include(
      mode: :capability,
      status: :resolved,
      candidate_names: [:pricing_node],
      selected_peer_view: include(peer: :pricing_node)
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :diagnostics_report)).to include(
      kind: :transport,
      status: :completed,
      query: include(required_capabilities: [:pricing]),
      route: include(peer: :pricing_node, mode: :capability),
      placement: include(mode: :direct),
      projection_report: include(mode: :capability, candidate_names: [:pricing_node]),
      admission: include(allowed: true),
      event_log: include(
        event_count: 4,
        events: include(
          include(kind: :placement, status: :resolved),
          include(kind: :projection, status: :resolved),
          include(kind: :route, status: :resolved),
          include(kind: :admission, status: :allowed)
        )
      ),
      operator_timeline: include(kind: :transport, status: :completed, event_count: 4)
    )
  end

  it "accepts an explicit capability query object for compose routing" do
    cluster = Igniter::Cluster.with(Igniter::Extensions::Contracts::ComposePack)
    query = Igniter::Cluster::CapabilityQuery.new(
      required_capabilities: [:pricing],
      preferred_peer: :pricing_node,
      metadata: { region: "eu-west" }
    )

    cluster.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      transport: build_peer_transport(cluster.application.profile.contracts_profile)
    )

    result = cluster.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: cluster.compose_invoker(query: query, namespace: :mesh) do
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      output :pricing_total
    end

    entry = cluster.application.fetch_session("mesh/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(120.0)
    expect(entry.payload.fetch(:transport).dig(:cluster, :query)).to include(
      required_capabilities: [:pricing],
      preferred_peer: :pricing_node,
      metadata: { region: "eu-west" }
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :mode)).to eq(:pinned)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :explanation)).to include(
      code: :pinned_route
    )
  end

  it "routes collection sessions through a pinned peer" do
    cluster = Igniter::Cluster.with(Igniter::Extensions::Contracts::CollectionPack)

    cluster.register_peer(
      :batch_node,
      capabilities: %i[pricing collection],
      transport: build_peer_transport(cluster.application.profile.contracts_profile)
    )

    result = cluster.run(
      inputs: {
        items: [
          { sku: "a", amount: 10 },
          { sku: "b", amount: 20 }
        ],
        tax_rate: 0.2
      }
    ) do
      input :items
      input :tax_rate

      collection :priced_items,
                 from: :items,
                 key: :sku,
                 inputs: { tax_rate: :tax_rate },
                 via: cluster.collection_invoker(peer: :batch_node, namespace: :mesh) do
        input :sku
        input :amount
        input :tax_rate

        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end

        output :total
      end

      output :priced_items
    end

    entry = cluster.application.fetch_session("mesh/priced_items/1")

    expect(result.output(:priced_items).fetch("b").output(:total)).to eq(24.0)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :peer)).to eq(:batch_node)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :mode)).to eq(:pinned)
  end

  it "supports declarative route policies on the cluster kernel" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .route_policy(:loose, require_capabilities: false)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: [:compose],
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    result = environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: environment.compose_invoker(
                capabilities: [:pricing],
                namespace: :mesh
              ) do
        input :amount
        input :tax_rate
        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end
        output :total
      end

      output :pricing_total
    end

    entry = environment.application.fetch_session("mesh/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(120.0)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :peer)).to eq(:fallback_node)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :mode)).to eq(:capability)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :metadata, :policy)).to include(
      name: :loose,
      require_capabilities: false
    )
  end

  it "supports declarative placement policies on the cluster kernel" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .route_policy(:loose, require_capabilities: false)
                              .placement_policy(:targeted, filter_capabilities: true, candidate_limit: 1)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: [:compose],
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    result = environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: environment.compose_invoker(capabilities: [:pricing], namespace: :mesh) do
        input :amount
        input :tax_rate
        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end
        output :total
      end

      output :pricing_total
    end

    entry = environment.application.fetch_session("mesh/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(120.0)
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :mode)).to eq(:capability_filtered)
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :candidates)).to eq([:pricing_node])
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :metadata, :candidate_profiles)).to contain_exactly(
      include(
        name: :pricing_node,
        capabilities: %i[compose pricing],
        topology: include(region: nil, zone: nil, labels: {})
      )
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :metadata, :candidate_peer_views)).to contain_exactly(
      include(
        peer: :pricing_node,
        included: true,
        capability_match: true,
        topology_match: true,
        preferred_peer_match: true,
        profile: include(name: :pricing_node)
      )
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :metadata, :membership_projection)).to include(
      candidate_names: [:pricing_node],
      candidate_views: include(include(peer: :pricing_node, included: true)),
      stages: include(
        include(name: :source),
        include(name: :preferred_peer),
        include(name: :topology),
        include(name: :capabilities),
        include(name: :candidate_limit)
      )
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :projection_report)).to include(
      mode: :capability_filtered,
      status: :resolved,
      candidate_names: [:pricing_node]
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :metadata, :policy)).to include(
      name: :targeted,
      filter_capabilities: true,
      candidate_limit: 1
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :peer)).to eq(:pricing_node)
  end

  it "routes and places using richer query intent over traits, labels, and zone" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .placement_policy(:targeted, filter_capabilities: true)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    result = environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
      input :subtotal
      input :rate

      compose :pricing_total,
              inputs: { amount: :subtotal, tax_rate: :rate },
              output: :total,
              via: environment.compose_invoker(
                capabilities: [:pricing],
                traits: [:financial],
                labels: { tier: "gold" },
                region: :eu_west,
                zone: :eu_west_1a,
                namespace: :mesh
              ) do
        input :amount
        input :tax_rate
        compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
          amount + (amount * tax_rate)
        end
        output :total
      end

      output :pricing_total
    end

    entry = environment.application.fetch_session("mesh/pricing_total/1")

    expect(result.output(:pricing_total)).to eq(120.0)
    expect(entry.payload.fetch(:transport).dig(:cluster, :query)).to include(
      required_capabilities: [:pricing],
      required_traits: [:financial],
      required_labels: { tier: "gold" },
      preferred_region: "eu_west",
      preferred_zone: "eu_west_1a"
    )
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :mode)).to eq(:capability_filtered)
    expect(entry.payload.fetch(:transport).dig(:cluster, :placement, :candidates)).to eq([:pricing_node])
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :peer)).to eq(:pricing_node)
    expect(entry.payload.fetch(:transport).dig(:cluster, :route, :explanation)).to include(
      code: :intent_route
    )
  end

  it "builds explicit rebalance plans from topology policy" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_rebalance(
      capabilities: [:pricing],
      traits: [:financial],
      metadata: { source: :cluster_spec }
    )

    expect(plan.to_h).to include(
      mode: :rebalance,
      source_names: [:fallback_node],
      destination_names: [:pricing_node],
      metadata: include(
        source: :cluster_spec,
        policy: include(name: :locality),
        query: include(required_traits: [:financial], preferred_zone: "eu_west_1a")
      ),
      explanation: include(code: :topology_rebalance)
    )
    expect(plan.moves.map(&:to_h)).to contain_exactly(
      include(
        source: :fallback_node,
        destination: :pricing_node,
        reason: include(code: :topology_move)
      )
    )
  end

  it "executes rebalance plans through the cluster plan executor" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_rebalance(capabilities: [:pricing], traits: [:financial])
    report = environment.execute_rebalance_plan(plan)

    expect(report).to be_a(Igniter::Cluster::PlanExecutionReport)
    expect(report.completed?).to be(true)
    expect(report.to_h).to include(
      plan_kind: :rebalance,
      status: :completed,
      action_types: [:rebalance_action],
      explanation: include(code: :rebalance_execution)
    )
    expect(report.action_results).to contain_exactly(
      have_attributes(
        action_type: :rebalance_action,
        status: :completed
      )
    )
    expect(report.action_results.first.to_h).to include(
      subject: {
        source: :fallback_node,
        destination: :pricing_node
      },
      metadata: include(simulated: true)
    )
  end

  it "builds explicit ownership plans from ownership policy" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_ownership(
      target: "order-42",
      capabilities: [:pricing],
      traits: [:financial],
      metadata: { source: :cluster_spec }
    )

    expect(plan.to_h).to include(
      mode: :assigned,
      owner_names: [:pricing_node],
      targets: ["order-42"],
      metadata: include(
        source: :cluster_spec,
        policy: include(name: :distributed, owner_limit: 1),
        target: "order-42",
        candidate_owner_names: [:pricing_node]
      ),
      explanation: include(code: :ownership_plan)
    )
    expect(plan.claims.map(&:to_h)).to contain_exactly(
      include(
        target: "order-42",
        owner: :pricing_node,
        reason: include(code: :ownership_assigned)
      )
    )
  end

  it "executes ownership and lease plans through explicit cluster execution reports" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .lease_policy(:ephemeral, ttl_seconds: 120, renewable: true)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    ownership_plan = environment.plan_ownership(target: "order-42", capabilities: [:pricing], traits: [:financial])
    ownership_report = environment.execute_ownership_plan(ownership_plan)
    lease_plan = environment.plan_lease(target: "order-42", ownership_plan: ownership_plan)
    lease_report = environment.execute_lease_plan(lease_plan) do |plan_kind:, action:, environment:|
      _unused_plan_kind = plan_kind
      {
        executed_by: :spec_handler,
        owner: action.owner.name,
        cluster: environment.profile.to_h.fetch(:placement)
      }
    end

    expect(ownership_report.to_h).to include(
      plan_kind: :ownership,
      status: :completed,
      action_types: [:ownership_action],
      incident: include(
        kind: :ownership_shift,
        status: :completed,
        severity: :medium,
        owner_names: [:pricing_node],
        targets: ["order-42"]
      ),
      recovery_timeline: include(
        kind: :ownership_shift,
        status: :completed,
        event_count: 3,
        event_log: include(
          events: include(
            include(kind: :incident_detected),
            include(kind: :ownership_action, status: :completed),
            include(kind: :recovery_outcome, status: :recovered)
          )
        )
      )
    )
    expect(lease_report.to_h).to include(
      plan_kind: :lease,
      status: :completed,
      action_types: [:lease_action],
      incident: include(
        kind: :lease,
        status: :completed,
        severity: :medium,
        owner_names: [:pricing_node],
        targets: ["order-42"]
      ),
      recovery_timeline: include(
        kind: :lease,
        status: :completed,
        event_count: 3,
        event_log: include(
          events: include(
            include(kind: :incident_detected),
            include(kind: :lease_action, status: :completed),
            include(kind: :recovery_outcome, status: :recovered)
          )
        )
      )
    )
    expect(lease_report.action_results.first.to_h).to include(
      subject: {
        target: "order-42",
        owner: :pricing_node
      },
      metadata: include(simulated: false, executed_by: :spec_handler)
    )
  end

  it "builds explicit lease plans from lease policy over ownership" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .lease_policy(:ephemeral, ttl_seconds: 120, renewable: true)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_lease(
      target: "order-42",
      capabilities: [:pricing],
      traits: [:financial],
      metadata: { source: :cluster_spec }
    )

    expect(plan.to_h).to include(
      mode: :granted,
      owner_names: [:pricing_node],
      targets: ["order-42"],
      metadata: include(
        source: :cluster_spec,
        policy: include(name: :ephemeral, ttl_seconds: 120, renewable: true),
        ownership: include(
          mode: :assigned,
          owner_names: [:pricing_node],
          targets: ["order-42"]
        )
      ),
      explanation: include(code: :lease_plan)
    )
    expect(plan.grants.map(&:to_h)).to contain_exactly(
      include(
        target: "order-42",
        owner: :pricing_node,
        ttl_seconds: 120,
        renewable: true,
        reason: include(code: :lease_granted)
      )
    )
  end

  it "executes failover plans through the generic cluster execute_plan entrypoint" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .health_policy(:availability_aware, trigger_statuses: [:unhealthy])
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      health_status: :unhealthy,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_failover(target: "order-42", capabilities: [:pricing], traits: [:financial])
    report = environment.execute_plan(plan)

    expect(report.to_h).to include(
      plan_kind: :failover,
      status: :completed,
      action_types: [:failover_action],
      incident: include(
        kind: :degraded_health,
        status: :completed,
        severity: :high,
        source_names: [:fallback_node],
        destination_names: [:pricing_node],
        targets: ["order-42"]
      ),
      recovery_timeline: include(
        kind: :degraded_health,
        status: :completed,
        event_count: 3,
        event_log: include(
          events: include(
            include(kind: :incident_detected),
            include(kind: :failover_action, status: :completed),
            include(kind: :recovery_outcome, status: :recovered)
          )
        )
      ),
      explanation: include(code: :failover_execution)
    )
    expect(report.action_results.first.to_h).to include(
      subject: {
        target: "order-42",
        source: :fallback_node,
        destination: :pricing_node
      }
    )
  end

  it "persists cluster incidents as durable state and keeps only unresolved incidents active" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .health_policy(:availability_aware, trigger_statuses: [:unhealthy])
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      health_status: :unhealthy,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_failover(target: "order-42", capabilities: [:pricing], traits: [:financial])
    failed_report = environment.execute_failover_plan(plan) do
      raise "peer write failed"
    end

    expect(failed_report.to_h).to include(
      status: :failed,
      incident: include(kind: :degraded_health, status: :failed)
    )
    expect(environment.incidents.map(&:to_h)).to contain_exactly(
      include(
        id: "degraded_health/1",
        plan_kind: :failover,
        status: :failed,
        resolution: :unresolved,
        active: true,
        incident: include(kind: :degraded_health, targets: ["order-42"])
      )
    )
    expect(environment.active_incidents.to_h).to include(
      count: 1,
      entries: include(
        include(
          id: "degraded_health/1",
          active: true,
          resolution: :unresolved
        )
      )
    )

    resolved_report = environment.execute_failover_plan(plan)
    resolved_entry = environment.incidents.last

    expect(resolved_report.to_h).to include(
      status: :completed,
      incident: include(kind: :degraded_health, status: :completed)
    )
    expect(environment.fetch_incident(resolved_entry.id).to_h).to include(
      id: "degraded_health/2",
      status: :completed,
      resolution: :recovered,
      active: false
    )
    expect(environment.active_incidents).to be_empty
    expect(environment.active_incidents.to_h).to include(
      count: 0,
      incident_keys: []
    )
  end

  it "builds and executes remediation plans from active incidents" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .health_policy(:availability_aware, trigger_statuses: [:unhealthy])
                              .remediation_policy(:default)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      health_status: :unhealthy,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    incident_plan = environment.plan_failover(target: "order-42", capabilities: [:pricing], traits: [:financial])
    environment.execute_failover_plan(incident_plan) do
      raise "peer write failed"
    end

    remediation_plan = environment.plan_remediation(metadata: { source: :cluster_spec })
    remediation_report = environment.execute_remediation_plan(remediation_plan)

    expect(remediation_plan.to_h).to include(
      mode: :planned,
      targets: ["order-42"],
      action_kinds: [:retry_failover],
      metadata: include(source: :cluster_spec, active_incident_count: 1),
      explanation: include(code: :remediation_plan)
    )
    expect(remediation_plan.steps.map(&:to_h)).to contain_exactly(
      include(
        incident_kind: :degraded_health,
        target: "order-42",
        action: :retry_failover
      )
    )
    expect(remediation_report.to_h).to include(
      plan_kind: :remediation,
      status: :completed,
      action_types: [:remediation_action],
      incident: nil,
      recovery_timeline: nil,
      explanation: include(code: :remediation_execution)
    )
    expect(remediation_report.action_results.first.to_h).to include(
      action_type: :remediation_action,
      subject: {
        incident_id: "degraded_health/1",
        incident_kind: :degraded_health,
        target: "order-42",
        action: :retry_failover
      }
    )
    expect(environment.incidents.length).to eq(1)
    expect(environment.active_incidents.count).to eq(1)
    expect(environment.incident_workflow("degraded_health/1").to_h).to include(
      state: :remediation_completed,
      active: true,
      action_kinds: [:remediation_completed]
    )
  end

  it "records operator incident workflow actions through environment helpers" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .health_policy(:availability_aware, trigger_statuses: [:unhealthy])
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      health_status: :unhealthy,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_failover(target: "order-42", capabilities: [:pricing], traits: [:financial])
    environment.execute_failover_plan(plan) do
      raise "peer write failed"
    end

    environment.acknowledge_incident("degraded_health/1", actor: :operator, note: "triaged")
    environment.assign_incident("degraded_health/1", assignee: :sre, actor: :operator)
    environment.silence_incident("degraded_health/1", actor: :operator, metadata: { minutes: 15 })

    expect(environment.incident_workflow("degraded_health/1").to_h).to include(
      state: :silenced,
      active: true,
      action_kinds: %i[acknowledged assigned silenced],
      actions: include(
        include(kind: :assigned, metadata: include(assignee: :sre)),
        include(kind: :silenced, metadata: include(minutes: 15))
      )
    )
    expect(environment.active_incidents.count).to eq(1)

    environment.resolve_incident("degraded_health/1", actor: :operator, note: "manual recovery confirmed")

    expect(environment.incident_workflow("degraded_health/1").to_h).to include(
      state: :resolved,
      active: false,
      action_kinds: %i[acknowledged assigned silenced resolved]
    )
    expect(environment.active_incidents).to be_empty
    expect(environment.incident_workflows.map(&:to_h)).to contain_exactly(
      include(state: :resolved, action_count: 4)
    )
  end

  it "routes cluster plan execution through a mesh executor with explicit trace metadata" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_mesh_transport
    )

    plan = environment.plan_rebalance(capabilities: [:pricing], traits: [:financial])
    report = environment.execute_plan_via_mesh(plan, metadata: { source: :cluster_spec })

    expect(report.to_h).to include(
      plan_kind: :rebalance,
      status: :completed,
      action_types: [:rebalance_action]
    )
    expect(report.action_results.first.to_h).to include(
      metadata: include(
        simulated: false,
        accepted_by: :pricing_node
      ),
      explanation: include(code: :mesh_rebalance_action)
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh)).to include(
      plan_kind: :rebalance,
      explanation: include(code: :mesh_rebalance_execution)
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :candidate_projection)).to include(
      candidate_names: [:pricing_node],
      stages: include(
        include(name: :membership_health),
        include(name: :discovery),
        include(name: :admission)
      )
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :candidate_projection_report)).to include(
      mode: :mesh_candidates,
      status: :resolved,
      candidate_names: [:pricing_node],
      stages: include(include(name: :membership_health), include(name: :discovery), include(name: :admission))
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :diagnostics_report)).to include(
      kind: :mesh,
      status: :completed,
      query: include(preferred_peer: :pricing_node),
      projection_report: include(mode: :mesh_candidates, candidate_names: [:pricing_node]),
      mesh: include(plan_kind: :rebalance, attempt_count: 1, attempt_statuses: [:completed]),
      event_log: include(
        event_count: 3,
        events: include(
          include(kind: :projection, status: :resolved),
          include(kind: :mesh_attempt, status: :completed),
          include(kind: :mesh, status: :completed)
        )
      ),
      operator_timeline: include(kind: :mesh, status: :completed, event_count: 3)
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :attempts)).to contain_exactly(
      include(
        peer: :pricing_node,
        status: :completed,
        membership_delta: include(joined_peer_names: []),
        request: include(
          trace_id: "mesh/rebalance/pricing_node/1",
          action_type: :rebalance_action
        )
      )
    )
  end

  it "retries mesh plan execution across discovered peers and accumulates attempts in trace" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :pricing_node_a,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_failing_mesh_transport
    )
    environment.register_peer(
      :pricing_node_b,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      transport: build_mesh_transport
    )

    plan = environment.plan_ownership(target: "order-42", capabilities: [:pricing], traits: [:financial])
    report = environment.execute_plan_via_mesh(
      plan,
      executor: environment.mesh_executor(
        retry_policy: Igniter::Cluster::MeshRetryPolicy.new(name: :fallback, max_attempts: 2)
      ),
      metadata: { source: :cluster_spec }
    )

    expect(report.completed?).to be(true)
    expect(report.action_results.first.to_h).to include(
      metadata: include(
        simulated: false,
        accepted_by: :pricing_node_b
      )
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :attempts)).to contain_exactly(
      include(peer: :pricing_node_a, status: :failed),
      include(peer: :pricing_node_b, status: :completed)
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata)).to include(
      retry_policy: include(name: :fallback, max_attempts: 2),
      candidate_projections: include(
        include(
          candidate_names: %i[pricing_node_a pricing_node_b],
          stages: include(include(name: :membership_health), include(name: :discovery), include(name: :admission))
        ),
        include(
          candidate_names: [:pricing_node_b],
          stages: include(include(name: :membership_health), include(name: :discovery), include(name: :admission))
        )
      )
    )
  end

  it "filters mesh candidates through trust admission and records denied peers in trace" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .ownership_policy(:distributed, owner_limit: 2)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :pricing_node_a,
      capabilities: %i[pricing compose],
      roles: [:untrusted],
      labels: { tier: "gold" },
      metadata: { trust: :low },
      transport: build_mesh_transport
    )
    environment.register_peer(
      :pricing_node_b,
      capabilities: %i[pricing compose],
      roles: [:trusted],
      labels: { tier: "gold" },
      metadata: { trust: :high },
      transport: build_mesh_transport
    )

    plan = environment.plan_ownership(target: "order-42", capabilities: [:pricing])
    report = environment.execute_plan_via_mesh(
      plan,
      executor: environment.mesh_executor(
        trust_policy: Igniter::Cluster::MeshTrustPolicy.new(
          name: :trusted_only,
          required_roles: [:trusted],
          required_metadata: { trust: :high }
        )
      )
    )

    expect(report.completed?).to be(true)
    expect(report.action_results.first.to_h).to include(
      metadata: include(
        accepted_by: :pricing_node_b
      )
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :admission_results)).to include(
      include(peer: :pricing_node_a, allowed: false, code: :missing_roles),
      include(peer: :pricing_node_b, allowed: true, code: :mesh_trust_accept)
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :candidate_projection)).to include(
      candidate_names: [:pricing_node_b],
      stages: include(
        include(name: :membership_health, output_peer_names: %i[pricing_node_a pricing_node_b]),
        include(name: :discovery, output_peer_names: %i[pricing_node_a pricing_node_b]),
        include(name: :admission, output_peer_names: [:pricing_node_b])
      )
    )
  end

  it "tracks membership versions and events across mesh retry attempts" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .ownership_policy(:distributed, owner_limit: 1)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :pricing_node_a,
      capabilities: %i[pricing compose],
      roles: [:trusted],
      metadata: { trust: :high },
      transport: build_failing_mesh_transport
    )
    environment.register_peer(
      :pricing_node_b,
      capabilities: %i[pricing compose],
      roles: [:trusted],
      metadata: { trust: :high },
      transport: build_mesh_transport
    )

    plan = environment.plan_ownership(target: "order-42", capabilities: [:pricing])
    report = environment.execute_plan_via_mesh(
      plan,
      executor: environment.mesh_executor(
        retry_policy: Igniter::Cluster::MeshRetryPolicy.new(name: :fallback, max_attempts: 2),
        membership_source: DynamicMembershipSource.new(
          first_peers: [:pricing_node_a],
          second_peers: %i[pricing_node_a pricing_node_b]
        )
      )
    )

    expect(report.completed?).to be(true)
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :attempts)).to contain_exactly(
      include(
        peer: :pricing_node_a,
        status: :failed,
        membership: include(
          source: :dynamic_spec,
          snapshot_id: "dynamic_spec/1",
          version: 1,
          epoch: "dynamic/1",
          lineage: ["dynamic_spec/1"]
        )
      ),
      include(
        peer: :pricing_node_b,
        status: :completed,
        membership: include(
          source: :dynamic_spec,
          snapshot_id: "dynamic_spec/2",
          previous_snapshot_id: "dynamic_spec/1",
          version: 2,
          epoch: "dynamic/2",
          lineage: %w[dynamic_spec/1 dynamic_spec/2]
        )
      )
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :memberships)).to include(
      include(
        source: :dynamic_spec,
        snapshot_id: "dynamic_spec/1",
        version: 1,
        epoch: "dynamic/1"
      ),
      include(
        source: :dynamic_spec,
        snapshot_id: "dynamic_spec/2",
        previous_snapshot_id: "dynamic_spec/1",
        version: 2,
        epoch: "dynamic/2",
        lineage: %w[dynamic_spec/1 dynamic_spec/2],
        events: include(include(type: :peer_joined, peer: :pricing_node_b))
      )
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata)).to include(
      membership_feed: include(
        name: :dynamic_membership_source,
        discovery_feed: include(name: :dynamic_discovery_source)
      ),
      membership_delta: include(
        feed: include(name: :dynamic_membership_source),
        joined_peer_names: [:pricing_node_b]
      ),
      membership_deltas: include(
        include(
          feed: include(name: :dynamic_membership_source),
          to_snapshot_ref: include(snapshot_id: "dynamic_spec/1")
        ),
        include(
          feed: include(name: :dynamic_membership_source),
          from_snapshot_ref: include(snapshot_id: "dynamic_spec/1"),
          to_snapshot_ref: include(snapshot_id: "dynamic_spec/2"),
          joined_peer_names: [:pricing_node_b]
        )
      ),
      membership_snapshot_ref: include(
        feed: include(name: :dynamic_membership_source),
        snapshot_id: "dynamic_spec/2",
        previous_snapshot_id: "dynamic_spec/1"
      ),
      membership_snapshot_refs: include(
        include(feed: include(name: :dynamic_membership_source), snapshot_id: "dynamic_spec/1"),
        include(feed: include(name: :dynamic_membership_source), snapshot_id: "dynamic_spec/2")
      ),
      membership_snapshots: include(
        include(feed: include(name: :dynamic_membership_source), snapshot_id: "dynamic_spec/1"),
        include(feed: include(name: :dynamic_membership_source), snapshot_id: "dynamic_spec/2")
      )
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :membership_source)).to include(
      name: :dynamic_membership_source
    )
    expect(report.action_results.first.to_h.dig(:metadata, :mesh, :metadata, :candidate_projections)).to include(
      include(
        candidate_names: [:pricing_node_a],
        stages: include(include(name: :discovery, output_peer_names: [:pricing_node_a]))
      ),
      include(
        candidate_names: [:pricing_node_b],
        stages: include(include(name: :discovery, output_peer_names: [:pricing_node_b]))
      )
    )
  end

  it "builds explicit failover plans from health policy over ownership and topology" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .capability(:pricing, traits: [:financial], labels: { domain: "commerce" })
                              .topology_policy(
                                :locality,
                                required_labels: { tier: "gold" },
                                preferred_zone: :eu_west_1a
                              )
                              .ownership_policy(:distributed, owner_limit: 1)
                              .health_policy(:availability_aware, trigger_statuses: %i[degraded unhealthy])
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :fallback_node,
      capabilities: %i[pricing compose],
      labels: { tier: "silver" },
      region: :eu_west,
      zone: :eu_west_1b,
      health_status: :degraded,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      labels: { tier: "gold" },
      region: :eu_west,
      zone: :eu_west_1a,
      health_status: :healthy,
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    plan = environment.plan_failover(
      target: "order-42",
      capabilities: [:pricing],
      traits: [:financial],
      metadata: { source: :cluster_spec }
    )

    expect(plan.to_h).to include(
      mode: :failover,
      source_names: [:fallback_node],
      destination_names: [:pricing_node],
      targets: ["order-42"],
      metadata: include(
        source: :cluster_spec,
        policy: include(name: :availability_aware, trigger_statuses: %i[degraded unhealthy]),
        ownership: include(
          mode: :assigned,
          owner_names: [:pricing_node],
          targets: ["order-42"]
        )
      ),
      explanation: include(code: :failover_plan)
    )
    expect(plan.steps.map(&:to_h)).to contain_exactly(
      include(
        target: "order-42",
        source: :fallback_node,
        destination: :pricing_node,
        reason: include(code: :failover_assignment)
      )
    )
  end

  it "surfaces admission failures before transport dispatch" do
    denying_admission = Class.new do
      def admit(request:, route:)
        Igniter::Cluster::AdmissionResult.denied(
          code: :policy_denied,
          metadata: { peer: route.peer.name },
          reason: Igniter::Cluster::DecisionExplanation.new(
            code: :policy_denied,
            message: "policy rejected #{request.session_id}",
            metadata: { peer: route.peer.name }
          )
        )
      end
    end.new

    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .admission(:strict, seam: denying_admission)
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    expect do
      environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
        input :subtotal
        input :rate

        compose :pricing_total,
                inputs: { amount: :subtotal, tax_rate: :rate },
                output: :total,
                via: environment.compose_invoker(capabilities: [:pricing], namespace: :mesh) do
          input :amount
          input :tax_rate
          compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
            amount + (amount * tax_rate)
          end
          output :total
        end

        output :pricing_total
      end
    end.to raise_error(Igniter::Cluster::AdmissionError, /policy_denied/)
  end

  it "supports declarative admission policies on the cluster kernel" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
                              .admission_policy(:restricted, blocked_peers: [:pricing_node])
                              .finalize
    environment = described_class.new(profile: cluster)
    environment.register_peer(
      :pricing_node,
      capabilities: %i[pricing compose],
      transport: build_peer_transport(environment.application.profile.contracts_profile)
    )

    expect do
      environment.run(inputs: { subtotal: 100, rate: 0.2 }) do
        input :subtotal
        input :rate

        compose :pricing_total,
                inputs: { amount: :subtotal, tax_rate: :rate },
                output: :total,
                via: environment.compose_invoker(capabilities: [:pricing], namespace: :mesh) do
          input :amount
          input :tax_rate
          compute :total, depends_on: %i[amount tax_rate] do |amount:, tax_rate:|
            amount + (amount * tax_rate)
          end
          output :total
        end

        output :pricing_total
      end
    end.to raise_error(Igniter::Cluster::AdmissionError, /blocked_peer/)
  end

  it "finalizes cluster profiles over application profiles and peers" do
    cluster = Igniter::Cluster.build_kernel(Igniter::Extensions::Contracts::ComposePack)
    cluster.register_peer(
      :pricing_node,
      capabilities: [:pricing],
      transport: build_peer_transport(cluster.application_kernel.finalize.contracts_profile)
    )
    profile = cluster.finalize

    expect(profile.to_h).to include(
      transport: :direct,
      router: :capability,
      route_policy: include(name: :capability),
      admission: :permissive,
      admission_policy: include(name: :permissive),
      placement: :direct,
      placement_policy: include(name: :direct),
      topology_policy: include(name: :locality_aware),
      ownership_policy: include(name: :distributed),
      lease_policy: include(name: :ephemeral),
      health_policy: include(name: :availability_aware),
      remediation_policy: include(
        name: :default,
        action_map: include(degraded_health: :retry_failover)
      ),
      peer_registry: :memory,
      incident_registry: :memory,
      active_incidents: include(count: 0, incident_keys: [])
    )
    expect(profile.to_h.fetch(:capability_catalog)).to eq(definitions: [])
    expect(profile.to_h.fetch(:application_profile).fetch(:contracts_packs)).to include("Igniter::Extensions::Contracts::ComposePack")
    expect(profile.to_h.fetch(:peers)).to contain_exactly(
      include(
        name: :pricing_node,
        capabilities: [:pricing],
        capability_definitions: [],
        roles: [],
        topology: { region: nil, zone: nil, labels: {}, metadata: {} },
        health: include(status: :healthy),
        labels: {},
        region: nil,
        zone: nil
      )
    )
  end
end
