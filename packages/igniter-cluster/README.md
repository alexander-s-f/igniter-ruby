# igniter-cluster

Clean-slate contracts-native distributed runtime for Igniter.

This package is intentionally separate from the archived cluster package.

- `igniter-cluster` is the new target package for distributed execution
- `packages/archive/igniter-cluster` remains reference-only until deletion

Primary entrypoints:

- `require "igniter-cluster"`
- `require "igniter/cluster"`

Primary API:

- `Igniter::Cluster.build_kernel`
- `Igniter::Cluster.build_profile`
- `Igniter::Cluster.with`
- `Igniter::Cluster::Kernel`
- `Igniter::Cluster::Profile`
- `Igniter::Cluster::Environment`
- `Igniter::Cluster::PlanExecutor`
- `Igniter::Cluster::MeshExecutor`
- `Igniter::Cluster::RemediationPolicy`
- `Igniter::Cluster::MeshMembership`
- `Igniter::Cluster::MeshMembershipSource`
- `Igniter::Cluster::RegistryMembershipSource`
- `Igniter::Cluster::PeerDiscovery`
- `Igniter::Cluster::MeshRetryPolicy`
- `Igniter::Cluster::MeshTrustPolicy`
- `Igniter::Cluster::MeshAdmission`

The first active slice is intentionally narrow:

- explicit `PeerProfile` identity model over name/capabilities/roles/labels
- explicit `PeerTopology` model for region/zone/labels locality
- richer `CapabilityQuery` intent over capabilities, traits, labels, region,
  and zone
- explicit `TopologyPolicy` and `RebalancePlan` for movement/rebalancing
  semantics
- explicit `OwnershipPolicy` and `OwnershipPlan` for workload/entity ownership
  planning
- explicit `LeasePolicy` and `LeasePlan` for TTL/renewal-aware coordination
  planning
- explicit `HealthPolicy` and `FailoverPlan` for degraded/failure transition
  planning
- explicit `RemediationPolicy` and `RemediationPlan` for response workflows over
  active incidents
- explicit cluster plan execution reports over rebalance/ownership/lease/failover
- explicit mesh execution requests, attempts, traces, and responses over cluster plans
- explicit mesh membership, discovery, and retry/fallback policy over peer execution
- explicit mesh trust/admission decisions and membership sources
- explicit `Peer` registry
- explicit `placement` seam
- declarative `PlacementPolicy` default
- declarative `RoutePolicy` and `AdmissionPolicy` defaults
- raw `router` and `admission` seams as low-level escape hatches
- raw `placement` seam as a low-level escape hatch
- explicit `transport` seam
- cluster-owned `compose_invoker`
- cluster-owned `collection_invoker`

The current implementation builds on `Igniter::Application::TransportRequest`
and `TransportResponse`, so the distributed path can grow without redesigning
contracts DSL or application session semantics.

Cluster planning can now be executed explicitly too:

- `Environment#execute_plan`
- `Environment#execute_rebalance_plan`
- `Environment#execute_ownership_plan`
- `Environment#execute_lease_plan`
- `Environment#execute_failover_plan`

By default these produce explicit simulated execution reports, leaving room for
future real handlers without changing the plan shapes.

Runnable illustrations live in `examples/cluster/`:

- `routing.rb` for capability-aware remote compose
- `incidents.rb` for durable incident history and active incident state
- `incident_workflow.rb` for acknowledge/assign/silence/resolve workflow actions
- `mesh_diagnostics.rb` for retry traces, projection reports, and operator-facing diagnostics
- `remediation.rb` for turning active incidents into executable response steps

Mesh-oriented execution now has a first dedicated adapter layer too:

- `Environment#mesh_executor`
- `Environment#execute_plan_via_mesh`
- `MeshExecutionRequest`
- `MeshExecutionResponse`
- `MeshExecutionAttempt`
- `MeshExecutionTrace`

This keeps mesh behavior above plan semantics: the same cluster plans can be
executed locally, simulated, or routed through mesh-aware peer transports.

Mesh execution is now membership-aware:

- `MeshMembership` snapshots available peers
- `PeerDiscovery` derives ordered candidate peers for a plan action
- `MeshRetryPolicy` controls retry/fallback across candidates

That gives mesh execution a real multi-attempt trace without baking discovery
or retry semantics into the plans themselves.

Mesh execution is now trust-aware too:

- `MeshMembershipSource` controls where membership snapshots come from
- `MeshTrustPolicy` expresses trust constraints over roles, labels, and metadata
- `MeshAdmission` records which peers were denied before execution

So mesh traces can now answer both:
- who we tried
- who we refused to try, and why
