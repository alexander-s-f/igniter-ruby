# frozen_string_literal: true

module Igniter
  module Cluster
    class MeshExecutor
      attr_reader :environment, :metadata, :discovery, :retry_policy, :admission, :membership_source,
                  :projection_policy, :projection_executor, :diagnostics_executor

      def initialize(environment:, metadata: {}, id_generator: nil, discovery: nil, retry_policy: nil,
                     admission: nil, trust_policy: nil, membership_source: nil)
        @environment = environment
        @metadata = metadata.dup.freeze
        @id_generator = id_generator || method(:default_trace_id)
        @discovery = discovery || PeerDiscovery.new
        @retry_policy = retry_policy || MeshRetryPolicy.new(name: :best_effort)
        @admission = admission || MeshAdmission.new(policy: trust_policy || MeshTrustPolicy.permissive)
        @membership_source = membership_source || RegistryMembershipSource.new
        @projection_policy = ProjectionPolicy.new(name: :mesh_candidates)
        @projection_executor = ProjectionExecutor.new(metadata: { scope: :mesh_candidates })
        @diagnostics_executor = ClusterDiagnosticsExecutor.new(metadata: { scope: :mesh })
        @sequence = 0
      end

      def call(plan:, plan_kind:, action:, environment: self.environment)
        membership = membership_source.call(
          environment: environment,
          allow_degraded: retry_policy.allow_degraded,
          metadata: metadata.merge(retry_policy: retry_policy.to_h)
        )
        attempts, trace_id, response, membership_history, admission_results, candidate_projections = execute_with_membership(
          plan: plan,
          plan_kind: plan_kind,
          action: action,
          environment: environment,
          membership: membership
        )
        if attempts.empty?
          return no_candidate_result(
            plan_kind: plan_kind,
            plan: plan,
            action: action,
            membership: membership,
            memberships: membership_history,
            admission_results: admission_results,
            candidate_projections: candidate_projections
          )
        end

        trace = build_trace(
          trace_id: trace_id,
          plan_kind: plan_kind,
          attempts: attempts,
          candidate_peers: membership_history.last.available_peers,
          membership: membership_history.last,
          memberships: membership_history,
          admission_results: admission_results,
          candidate_projections: candidate_projections
        )

        PlanActionResult.new(
          action_type: action_type_for(plan_kind),
          status: final_status(attempts),
          subject: subject_for(plan_kind, action),
          metadata: {
            simulated: false,
            mesh: trace.to_h,
            action: action.to_h
          }.merge(response.metadata),
          explanation: DecisionExplanation.new(
            code: :"mesh_#{plan_kind}_action",
            message: mesh_message(plan_kind, attempts.last.peer_name, final_status(attempts)),
            metadata: {
              peer: attempts.last.peer_name,
              trace_id: trace_id
            }
          )
        )
      rescue StandardError => e
        PlanActionResult.new(
          action_type: action_type_for(plan_kind),
          status: :failed,
          subject: subject_for(plan_kind, action),
          metadata: {
            simulated: false,
            error: {
              class: e.class.name,
              message: e.message
            }
          },
          explanation: DecisionExplanation.new(
            code: :"mesh_#{plan_kind}_failed",
            message: "mesh execution failed for #{plan_kind}",
            metadata: {
              error_class: e.class.name
            }
          )
        )
      end

      private

      def execute_with_membership(plan:, plan_kind:, action:, environment:, membership:)
        attempts = []
        memberships = [membership]
        admission_results = []
        candidate_projections = []
        attempted_names = []
        trace_id = nil
        last_response = MeshExecutionResponse.new(status: :skipped, metadata: {})
        current_membership = membership
        previous_membership = nil

        loop do
          discovered_peers = retry_policy.candidate_peers(
            discovery.peers_for(plan_kind: plan_kind, plan: plan, action: action, membership: current_membership)
          ).reject { |peer| attempted_names.include?(peer.name) }
          candidate_peers, new_admission_results, candidate_projection = admit_candidates(
            discovered_peers: discovered_peers,
            plan_kind: plan_kind,
            action: action,
            membership: current_membership
          )
          admission_results.concat(new_admission_results)
          candidate_projections << candidate_projection
          break if candidate_peers.empty?

          peer = candidate_peers.first
          attempted_names << peer.name
          trace_id ||= next_trace_id(plan_kind: plan_kind, peer_name: peer.name)
          request = build_request(
            trace_id: trace_id,
            plan_kind: plan_kind,
            action: action,
            peer: peer,
            membership: current_membership,
            membership_delta: current_membership.snapshot_delta(previous_membership: previous_membership)
          )
          response = normalize_response(peer.transport.call(request: request))
          attempts << MeshExecutionAttempt.new(
            peer_name: peer.name,
            status: response.status,
            request: request,
            response_metadata: response.metadata,
            membership: current_membership,
            membership_delta: current_membership.snapshot_delta(previous_membership: previous_membership),
            explanation: response.explanation || DecisionExplanation.new(
              code: :"mesh_#{response.status}",
              message: "#{response.status} mesh execution on #{peer.name}",
              metadata: response.metadata
            )
          )
          last_response = response
          break unless retry_policy.retryable_status?(response.status)

          refreshed_membership = membership_source.call(
            environment: environment,
            allow_degraded: retry_policy.allow_degraded,
            metadata: metadata.merge(retry_policy: retry_policy.to_h),
            previous_membership: current_membership
          )
          memberships << refreshed_membership
          previous_membership = current_membership
          current_membership = refreshed_membership
        end

        [
          attempts.freeze,
          trace_id,
          last_response,
          memberships.freeze,
          admission_results.freeze,
          candidate_projections.freeze
        ]
      end

      def admit_candidates(discovered_peers:, plan_kind:, action:, membership:)
        results = []
        candidates = []
        query = query_for(plan_kind: plan_kind, action: action)

        Array(discovered_peers).each do |peer|
          result = admission.admit(peer: peer, plan_kind: plan_kind, action: action, membership: membership)
          results << result
          candidates << peer if result.allowed?
        end

        projection = build_candidate_projection(
          query: query,
          membership: membership,
          discovered_peers: discovered_peers,
          admission_results: results,
          candidate_peers: candidates
        )

        [candidates.freeze, results.freeze, projection]
      end

      def normalize_response(raw_response)
        return raw_response if raw_response.is_a?(MeshExecutionResponse)

        metadata =
          case raw_response
          when Hash
            raw_response
          when nil
            {}
          else
            { handler_result: raw_response }
          end

        MeshExecutionResponse.new(
          status: :completed,
          metadata: metadata,
          explanation: DecisionExplanation.new(
            code: :mesh_completed,
            message: "mesh peer accepted action",
            metadata: metadata
          )
        )
      end

      def build_request(trace_id:, plan_kind:, action:, peer:, membership:, membership_delta:)
        MeshExecutionRequest.new(
          trace_id: trace_id,
          plan_kind: plan_kind,
          action_type: action_type_for(plan_kind),
          subject: subject_for(plan_kind, action),
          action: action.to_h,
          metadata: metadata.merge(
            peer: peer.to_h,
            membership_feed: membership.feed.to_h,
            membership_delta: membership_delta.to_h,
            membership_snapshot_ref: membership.snapshot_ref,
            membership_snapshot: membership.snapshot.to_h,
            membership: membership.to_h,
            membership_source: membership_source.to_h,
            retry_policy: retry_policy.to_h,
            discovery: discovery.to_h,
            admission: admission.to_h
          )
        )
      end

      def build_trace(trace_id:, plan_kind:, attempts:, candidate_peers:, membership:, memberships:, admission_results:,
                      candidate_projections:)
        MeshExecutionTrace.new(
          trace_id: trace_id,
          plan_kind: plan_kind,
          attempts: attempts,
          metadata: {
            candidate_peers: candidate_peers.map(&:to_h),
            membership_feed: membership.feed.to_h,
            membership_delta: membership.snapshot_delta(
              previous_membership: previous_membership_for(memberships, membership)
            ).to_h,
            membership_deltas: membership_deltas_for(memberships),
            membership_snapshot_ref: membership.snapshot_ref,
            membership_snapshot: membership.snapshot.to_h,
            membership_snapshot_refs: memberships.map(&:snapshot_ref),
            membership_snapshots: memberships.map { |entry| entry.snapshot.to_h },
            membership: membership.to_h,
            memberships: memberships.map(&:to_h),
            admission_results: admission_results.map(&:to_h),
            candidate_projection: candidate_projections.last&.to_h,
            candidate_projections: candidate_projections.map(&:to_h),
            candidate_projection_report: candidate_projections.last && projection_executor.execute(
              candidate_projections.last,
              metadata: { policy: projection_policy.to_h }
            ).to_h,
            candidate_projection_reports: candidate_projections.map do |projection|
              projection_executor.execute(projection, metadata: { policy: projection_policy.to_h }).to_h
            end,
            diagnostics_report: diagnostics_executor.execute_mesh(
              query: candidate_projections.last&.query&.to_h,
              projection_report: candidate_projections.last && projection_executor.execute(
                candidate_projections.last,
                metadata: { policy: projection_policy.to_h }
              ).to_h,
              mesh: mesh_summary(
                trace_id: trace_id,
                plan_kind: plan_kind,
                attempts: attempts,
                candidate_projection: candidate_projections.last
              ),
              status: final_status(attempts),
              metadata: { policy: projection_policy.to_h }
            ).to_h,
            projection_policy: projection_policy.to_h,
            membership_source: membership_source.to_h,
            mesh_executor: metadata.dup,
            retry_policy: retry_policy.to_h,
            discovery: discovery.to_h,
            admission: admission.to_h
          },
          explanation: DecisionExplanation.new(
            code: :"mesh_#{plan_kind}_execution",
            message: mesh_message(plan_kind, attempts.last.peer_name, final_status(attempts)),
            metadata: {
              peer: attempts.last.peer_name,
              status: final_status(attempts),
              attempt_count: attempts.length
            }
          )
        )
      end

      def no_candidate_result(plan_kind:, plan:, action:, membership:, memberships:, admission_results:,
                              candidate_projections:)
        PlanActionResult.new(
          action_type: action_type_for(plan_kind),
          status: :failed,
          subject: subject_for(plan_kind, action),
          metadata: {
            simulated: false,
            mesh: {
              plan_kind: plan_kind,
              candidate_peers: [],
              membership_feed: membership.feed.to_h,
              membership_delta: membership.snapshot_delta(
                previous_membership: previous_membership_for(memberships, membership)
              ).to_h,
              membership_deltas: membership_deltas_for(memberships),
              membership_snapshot_ref: membership.snapshot_ref,
              membership_snapshot: membership.snapshot.to_h,
              membership_snapshot_refs: memberships.map(&:snapshot_ref),
              membership_snapshots: memberships.map { |entry| entry.snapshot.to_h },
              membership: membership.to_h,
              memberships: memberships.map(&:to_h),
              admission_results: admission_results.map(&:to_h),
              candidate_projection: candidate_projections.last&.to_h,
              candidate_projections: candidate_projections.map(&:to_h),
              candidate_projection_report: candidate_projections.last && projection_executor.execute(
                candidate_projections.last,
                metadata: { policy: projection_policy.to_h }
              ).to_h,
              candidate_projection_reports: candidate_projections.map do |projection|
                projection_executor.execute(projection, metadata: { policy: projection_policy.to_h }).to_h
              end,
              diagnostics_report: diagnostics_executor.execute_mesh(
                query: candidate_projections.last&.query&.to_h,
                projection_report: candidate_projections.last && projection_executor.execute(
                  candidate_projections.last,
                  metadata: { policy: projection_policy.to_h }
                ).to_h,
                mesh: mesh_summary(
                  trace_id: nil,
                  plan_kind: plan_kind,
                  attempts: [],
                  candidate_projection: candidate_projections.last
                ),
                status: :failed,
                metadata: { policy: projection_policy.to_h }
              ).to_h,
              projection_policy: projection_policy.to_h,
              membership_source: membership_source.to_h,
              plan: plan.to_h,
              admission: admission.to_h
            }
          },
          explanation: DecisionExplanation.new(
            code: :"mesh_#{plan_kind}_unavailable",
            message: "no mesh candidate peer available for #{plan_kind}",
            metadata: {
              membership: membership.to_h
            }
          )
        )
      end

      def action_type_for(plan_kind)
        :"#{plan_kind}_action"
      end

      def final_status(attempts)
        return :failed if attempts.empty?
        return :completed if attempts.any?(&:completed?)
        return :skipped if attempts.all?(&:skipped?)

        :failed
      end

      def subject_for(plan_kind, action)
        case plan_kind.to_sym
        when :rebalance
          {
            source: action.source.name,
            destination: action.destination.name
          }
        when :ownership, :lease
          {
            target: action.target,
            owner: action.owner.name
          }
        when :failover
          {
            target: action.target,
            source: action.source.name,
            destination: action.destination.name
          }
        else
          action.to_h
        end
      end

      def mesh_message(plan_kind, peer_name, status)
        "#{status} #{plan_kind} mesh action via #{peer_name}"
      end

      def mesh_summary(trace_id:, plan_kind:, attempts:, candidate_projection:)
        {
          trace_id: trace_id,
          plan_kind: plan_kind.to_sym,
          attempt_count: Array(attempts).length,
          attempt_statuses: Array(attempts).map(&:status),
          candidate_names: candidate_projection&.candidate_names || []
        }
      end

      def membership_deltas_for(memberships)
        Array(memberships).each_with_index.map do |membership, index|
          membership.snapshot_delta(previous_membership: index.zero? ? nil : memberships.fetch(index - 1)).to_h
        end
      end

      def query_for(plan_kind:, action:)
        CapabilityQuery.new(
          preferred_peer: preferred_peer_for(plan_kind: plan_kind, action: action)
        )
      end

      def preferred_peer_for(plan_kind:, action:)
        case plan_kind.to_sym
        when :rebalance, :failover
          action.destination.name
        when :ownership, :lease
          action.owner.name
        end
      end

      def build_candidate_projection(query:, membership:, discovered_peers:, admission_results:, candidate_peers:)
        peer_views = membership.available_peers.map do |peer|
          PeerView.new(
            peer: peer,
            query: query,
            included: candidate_peers.include?(peer),
            metadata: {
              source: :mesh_candidates,
              admission_result: admission_results.find { |result| result.peer_name == peer.name }&.to_h
            }
          )
        end
        candidate_views = peer_views.select(&:included?)
        stages = projection_policy.project_mesh(
          query: query,
          membership: membership,
          discovered_peers: discovered_peers,
          admitted_results: admission_results
        )

        MembershipProjection.new(
          mode: :mesh_candidates,
          query: query,
          peer_views: peer_views,
          candidate_views: candidate_views,
          stages: stages,
          metadata: {
            source: :mesh_candidates,
            projection_policy: projection_policy.to_h
          },
          explanation: DecisionExplanation.new(
            code: :mesh_candidate_projection,
            message: "mesh candidate projection kept #{candidate_views.length} peer(s)",
            metadata: {
              candidate_names: candidate_views.map(&:name)
            }
          )
        )
      end

      def previous_membership_for(memberships, membership)
        index = Array(memberships).index(membership)
        return nil if index.nil? || index.zero?

        memberships.fetch(index - 1)
      end

      def next_trace_id(plan_kind:, peer_name:)
        @sequence += 1
        @id_generator.call(plan_kind: plan_kind, peer_name: peer_name, sequence: @sequence)
      end

      def default_trace_id(plan_kind:, peer_name:, sequence:)
        "mesh/#{plan_kind}/#{peer_name}/#{sequence}"
      end
    end
  end
end
