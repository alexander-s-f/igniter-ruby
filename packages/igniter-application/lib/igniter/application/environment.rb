# frozen_string_literal: true

require "securerandom"

module Igniter
  module Application
    class Environment
      attr_reader :profile, :provider_resolution_report, :provider_boot_report, :provider_shutdown_report

      def initialize(profile:)
        @profile = profile
      end

      def contracts
        @contracts ||= Igniter::Contracts::Environment.new(profile: profile.contracts_profile)
      end

      def compile(&block)
        contracts.compile(&block)
      end

      def validation_report(&block)
        contracts.validation_report(&block)
      end

      def compilation_report(&block)
        contracts.compilation_report(&block)
      end

      def execute(compiled_graph, inputs:)
        contracts.execute(compiled_graph, inputs: inputs)
      end

      def execute_with(executor_name, compiled_graph, inputs:, runtime: Igniter::Contracts::Execution::Runtime)
        contracts.execute_with(executor_name, compiled_graph, inputs: inputs, runtime: runtime)
      end

      def run(inputs:, &block)
        contracts.run(inputs: inputs, &block)
      end

      def diagnose(result)
        contracts.diagnose(result)
      end

      def apply_effect(effect_name, payload:, context: {})
        contracts.apply_effect(effect_name, payload: payload, context: context)
      end

      def service(name)
        return profile.service(name) if profile.supports_service?(name)

        resolved_provider_services.fetch(name.to_sym)
      end

      def service_definition(name)
        return profile.service_definition(name) if profile.service_registry.service?(name)

        resolved_provider_service_definitions.fetch(name.to_sym)
      end

      def interface(name)
        return profile.interface_definition(name).callable if profile.service_registry.interface?(name)

        resolved_provider_interfaces.fetch(name.to_sym)
      end

      def interface_definition(name)
        return profile.interface_definition(name) if profile.service_registry.interface?(name)

        resolved_provider_interface_definitions.fetch(name.to_sym)
      end

      def contract(name)
        profile.contract(name)
      end

      def config
        profile.config
      end

      def credentials
        profile.credentials
      end

      def manifest
        profile.manifest
      end

      def layout
        manifest.layout
      end

      def providers
        profile.providers
      end

      def provider(name)
        providers.find do |entry|
          entry.name == name.to_sym
        end&.provider || raise(KeyError, "unknown provider #{name.inspect}")
      end

      def ai_client(name = :default)
        profile.ai_client(name)
      end

      def ai_provider_names
        profile.ai_provider_names
      end

      def agent(name)
        profile.agent(name)
      end

      def agent_names
        profile.agent_names
      end

      def mount(name)
        profile.mount(name)
      end

      def mount?(name)
        profile.mount?(name)
      end

      def mounts
        profile.mounts.values.sort_by(&:name)
      end

      def mounts_by_kind(kind)
        profile.mounts_by_kind(kind)
      end

      def host_seam
        profile.host_seam
      end

      def loader_seam
        profile.loader_seam
      end

      def scheduler_seam
        profile.scheduler_seam
      end

      def session_store
        profile.session_store_seam
      end

      def plan_executor
        @plan_executor ||= PlanExecutor.new(environment: self)
      end

      def compose_invoker(invoker: Igniter::Extensions::Contracts::ComposePack::LocalInvoker, namespace: :compose,
                          metadata: {}, id_generator: nil)
        ComposeInvoker.new(
          environment: self,
          invoker: invoker,
          namespace: namespace,
          metadata: metadata,
          id_generator: id_generator
        )
      end

      def remote_compose_invoker(transport:, namespace: :remote_compose, metadata: {}, id_generator: nil)
        compose_invoker(
          namespace: namespace,
          metadata: metadata.merge(remote: true),
          id_generator: id_generator,
          invoker: ComposeTransportAdapter.new(
            transport: transport,
            metadata: metadata.merge(remote: true, namespace: namespace.to_s)
          )
        )
      end

      def collection_invoker(invoker: Igniter::Extensions::Contracts::CollectionPack::LocalInvoker,
                             namespace: :collection, metadata: {}, id_generator: nil)
        CollectionInvoker.new(
          environment: self,
          invoker: invoker,
          namespace: namespace,
          metadata: metadata,
          id_generator: id_generator
        )
      end

      def remote_collection_invoker(transport:, namespace: :remote_collection, metadata: {}, id_generator: nil)
        collection_invoker(
          namespace: namespace,
          metadata: metadata.merge(remote: true),
          id_generator: id_generator,
          invoker: CollectionTransportAdapter.new(
            transport: transport,
            metadata: metadata.merge(remote: true, namespace: namespace.to_s)
          )
        )
      end

      def load_code!(base_dir:)
        result = loader_seam.load!(base_dir: base_dir, paths: profile.code_paths, environment: self)
        @application_load_report = normalize_load_report(result)
        @loaded_base_dir = base_dir.to_s
        self
      end

      def start_scheduler
        scheduler_seam.start(environment: self)
        @scheduler_running = true
        self
      end

      def stop_scheduler
        scheduler_seam.stop(environment: self) if scheduler_seam.respond_to?(:stop)
        @scheduler_running = false
        self
      end

      def activate_transport!
        host_seam.activate!(environment: self)
        @transport_activated = true
        self
      end

      def boot(base_dir: Dir.pwd, load_code: true, start_scheduler: true, activate_transport: false)
        plan = plan_boot(
          base_dir: base_dir,
          load_code: load_code,
          start_scheduler: start_scheduler,
          activate_transport: activate_transport
        )
        execute_boot_plan(plan)
      end

      def booted?
        @booted == true
      end

      def shutdown(stop_scheduler: true, deactivate_transport: true)
        plan = plan_shutdown(
          stop_scheduler: stop_scheduler,
          deactivate_transport: deactivate_transport
        )
        execute_shutdown_plan(plan)
      end

      def snapshot
        Snapshot.new(profile: profile, runtime_state: runtime_state)
      end

      def plan_boot(base_dir: Dir.pwd, load_code: true, start_scheduler: true, activate_transport: false)
        BootPlan.new(
          base_dir: base_dir,
          steps: [
            build_boot_load_code_step(base_dir: base_dir, enabled: load_code),
            planned_plan_step(
              name: :resolve_providers,
              seam_name: :providers,
              action: :resolve,
              metadata: {
                providers: profile.provider_names
              }
            ),
            planned_plan_step(
              name: :boot_providers,
              seam_name: :providers,
              action: :boot,
              metadata: {
                providers: profile.provider_names
              }
            ),
            build_boot_scheduler_step(enabled: start_scheduler),
            build_boot_host_step(enabled: activate_transport)
          ],
          snapshot: snapshot
        )
      end

      def plan_shutdown(stop_scheduler: true, deactivate_transport: true)
        ShutdownPlan.new(
          steps: [
            build_shutdown_host_step(enabled: deactivate_transport),
            build_shutdown_scheduler_step(enabled: stop_scheduler),
            build_shutdown_provider_step
          ],
          snapshot: snapshot
        )
      end

      def execute_boot_plan(plan)
        plan_executor.boot(plan)
      end

      def execute_shutdown_plan(plan)
        plan_executor.shutdown(plan)
      end

      def fetch_session(id)
        session_store.fetch(id)
      end

      def sessions
        session_store.entries
      end

      def flow_session(id)
        FlowSessionSnapshot.from_entry(fetch_session(id))
      end

      def flow_sessions
        sessions.select { |entry| entry.kind == :flow }.map { |entry| FlowSessionSnapshot.from_entry(entry) }
      end

      def start_flow(flow_name, session_id: nil, input: {}, status: nil, current_step: nil, pending_inputs: [],
                     pending_actions: [], artifacts: [], metadata: {})
        resolved_session_id = session_id || "#{flow_name}/#{SecureRandom.uuid}"
        resolved_status = status || flow_status_for(pending_inputs: pending_inputs, pending_actions: pending_actions)
        snapshot = FlowSessionSnapshot.new(
          session_id: resolved_session_id,
          flow_name: flow_name,
          status: resolved_status,
          current_step: current_step,
          pending_inputs: pending_inputs,
          pending_actions: pending_actions,
          artifacts: artifacts,
          metadata: metadata.merge(input: input)
        )
        session_store.write(
          SessionEntry.new(
            id: resolved_session_id,
            kind: :flow,
            status: snapshot.status,
            metadata: {
              flow_name: snapshot.flow_name,
              profile_fingerprint: profile.contracts_profile.fingerprint
            }.merge(metadata),
            payload: snapshot.to_h,
            created_at: snapshot.created_at,
            updated_at: snapshot.updated_at
          )
        )
        snapshot
      end

      def resume_flow(session_id, event:, status: nil, pending_inputs: nil, pending_actions: nil, artifacts: nil)
        entry = fetch_session(session_id)
        raise ArgumentError, "session #{session_id.inspect} is not a flow session" unless entry.kind == :flow

        current = FlowSessionSnapshot.from_entry(entry)
        flow_event = FlowEvent.from(event, session_id: current.session_id)
        updated = current.with_event(
          flow_event,
          status: status || current.status,
          pending_inputs: pending_inputs.nil? ? current.pending_inputs : pending_inputs,
          pending_actions: pending_actions.nil? ? current.pending_actions : pending_actions,
          artifacts: artifacts.nil? ? current.artifacts : artifacts
        )
        session_store.write(
          entry.with_update(
            status: updated.status,
            payload: updated.to_h,
            updated_at: updated.updated_at
          )
        )
        updated
      end

      def run_compose_session(session_id:, compiled_graph:, inputs:,
                              invoker: Igniter::Extensions::Contracts::ComposePack::LocalInvoker, operation_name: nil, metadata: {})
        session_metadata = metadata.merge(
          operation_name: (operation_name || session_id).to_sym,
          profile_fingerprint: profile.contracts_profile.fingerprint
        )
        running_entry = SessionEntry.new(
          id: session_id,
          kind: :compose,
          status: :running,
          metadata: session_metadata,
          payload: { inputs: inputs }
        )
        session_store.write(running_entry)

        operation = Igniter::Contracts::Operation.new(kind: :compose, name: operation_name || session_id,
                                                      attributes: {})
        invocation = Igniter::Extensions::Contracts::ComposePack::Invocation.new(
          operation: operation,
          compiled_graph: compiled_graph,
          inputs: inputs,
          profile: profile.contracts_profile
        )
        raw_result = invoker.call(invocation: invocation)
        result, transport_metadata = normalize_compose_session_result(raw_result)
        unless result.is_a?(Igniter::Contracts::ExecutionResult)
          raise Igniter::Contracts::Error,
                "compose session invoker for #{session_id} must return an ExecutionResult"
        end

        session_store.write(
          running_entry.with_update(
            status: :completed,
            payload: {
              inputs: inputs,
              outputs: result.outputs.to_h,
              output_names: result.outputs.keys,
              transport: transport_metadata
            }
          )
        )
        result
      rescue StandardError => e
        session_store.write(
          running_entry.with_update(
            status: :failed,
            payload: {
              inputs: inputs,
              error: {
                class: e.class.name,
                message: e.message
              }
            }
          )
        )
        raise
      end

      def run_collection_session(session_id:, items:, compiled_graph:, key:, inputs: {},
                                 invoker: Igniter::Extensions::Contracts::CollectionPack::LocalInvoker, window: nil, operation_name: nil, metadata: {})
        session_metadata = metadata.merge(
          operation_name: (operation_name || session_id).to_sym,
          key: key.to_sym,
          profile_fingerprint: profile.contracts_profile.fingerprint
        )
        running_entry = SessionEntry.new(
          id: session_id,
          kind: :collection,
          status: :running,
          metadata: session_metadata,
          payload: {
            inputs: inputs,
            item_count: Array(items).size
          }
        )
        session_store.write(running_entry)

        operation = Igniter::Contracts::Operation.new(kind: :collection, name: operation_name || session_id,
                                                      attributes: {})
        invocation = Igniter::Extensions::Contracts::CollectionPack::Invocation.new(
          operation: operation,
          items: items,
          inputs: inputs,
          compiled_graph: compiled_graph,
          profile: profile.contracts_profile,
          key_name: key,
          window: window
        )
        raw_result = invoker.call(invocation: invocation)
        result, transport_metadata = normalize_collection_session_result(raw_result)
        unless result.is_a?(Igniter::Extensions::Contracts::Dataflow::CollectionResult)
          raise Igniter::Contracts::Error,
                "collection session invoker for #{session_id} must return a CollectionResult"
        end

        session_store.write(
          running_entry.with_update(
            status: :completed,
            payload: {
              inputs: inputs,
              item_count: Array(items).size,
              keys: result.keys,
              summary: result.summary,
              transport: transport_metadata
            }
          )
        )
        result
      rescue StandardError => e
        session_store.write(
          running_entry.with_update(
            status: :failed,
            payload: {
              inputs: inputs,
              item_count: Array(items).size,
              error: {
                class: e.class.name,
                message: e.message
              }
            }
          )
        )
        raise
      end

      def start_host
        activate_transport!
        host_seam.start(environment: self)
      end

      def rack_app
        activate_transport!
        host_seam.rack_app(environment: self)
      end

      private

      def flow_status_for(pending_inputs:, pending_actions:)
        Array(pending_inputs).empty? && Array(pending_actions).empty? ? :active : :waiting_for_user
      end

      def mark_booted!
        @booted = true
      end

      def mark_shutdown!
        @booted = false
      end

      def resolve_providers!
        return @provider_resolution_report if @providers_resolved == true

        @resolved_provider_services = {}
        @resolved_provider_service_definitions = {}
        @resolved_provider_interfaces = {}
        @resolved_provider_interface_definitions = {}
        results = []

        providers.each do |registration|
          services = registration.provider.services(environment: self)
          interfaces = registration.provider.interfaces(environment: self)

          normalize_provider_entries(
            services,
            registration: registration,
            definition_class: ServiceDefinition,
            values_map: @resolved_provider_services,
            definitions_map: @resolved_provider_service_definitions
          )
          normalize_provider_entries(
            interfaces,
            registration: registration,
            definition_class: Interface,
            values_map: @resolved_provider_interfaces,
            definitions_map: @resolved_provider_interface_definitions
          )

          provider_interface_entries(registration.name).each do |name, callable|
            @resolved_provider_services[name] ||= callable
            @resolved_provider_service_definitions[name] ||= ServiceDefinition.new(
              name: name,
              callable: callable,
              metadata: @resolved_provider_interface_definitions.fetch(name).metadata,
              source: registration.name
            )
          end

          results << ProviderLifecycleResult.new(
            provider_name: registration.name,
            phase: :resolve,
            status: :completed,
            service_names: provider_service_names(registration.name),
            interface_names: provider_interface_names(registration.name)
          )
        end

        @resolved_provider_services.freeze
        @resolved_provider_service_definitions.freeze
        @resolved_provider_interfaces.freeze
        @resolved_provider_interface_definitions.freeze
        @providers_resolved = true
        @provider_resolution_report = ProviderLifecycleReport.new(phase: :resolve, results: results)
      end

      def load_code_with_report(base_dir:)
        metadata = {
          base_dir: base_dir.to_s,
          path_groups: profile.path_groups,
          layout: layout.to_h
        }
        yield_result = nil
        result = execute_seam_action(seam_name: :loader, action: :load, metadata: metadata) do
          load_code!(base_dir: base_dir)
          yield_result = @application_load_report
        end
        @loader_result = result.with_metadata(metadata.merge(load_report: yield_result&.to_h))
      end

      def start_scheduler_with_report
        metadata = {
          scheduler: profile.scheduler_name,
          scheduled_jobs: profile.scheduled_job_names
        }
        execute_seam_action(seam_name: :scheduler, action: :start, metadata: metadata) do
          start_scheduler
        end
      end

      def stop_scheduler_with_report
        if @scheduler_running != true
          return skipped_seam_result(
            seam_name: :scheduler,
            action: :stop,
            metadata: {
              scheduler: profile.scheduler_name,
              scheduled_jobs: profile.scheduled_job_names
            }
          )
        end

        metadata = {
          scheduler: profile.scheduler_name,
          scheduled_jobs: profile.scheduled_job_names
        }
        execute_seam_action(seam_name: :scheduler, action: :stop, metadata: metadata) do
          stop_scheduler
        end
      end

      def activate_transport_with_report
        metadata = {
          host: profile.host_name
        }
        execute_seam_action(seam_name: :host, action: :activate_transport, metadata: metadata) do
          activate_transport!
        end
      end

      def deactivate_transport_with_report
        metadata = {
          host: profile.host_name
        }
        return skipped_seam_result(seam_name: :host, action: :deactivate_transport, metadata: metadata) unless @transport_activated == true
        return skipped_seam_result(seam_name: :host, action: :deactivate_transport, metadata: metadata) unless host_seam.respond_to?(:deactivate!)

        execute_seam_action(seam_name: :host, action: :deactivate_transport, metadata: metadata) do
          host_seam.deactivate!(environment: self)
          @transport_activated = false
          self
        end
      end

      def boot_providers!
        return @provider_boot_report if @providers_booted == true

        resolve_providers!
        results = []

        providers.each do |registration|
          registration.provider.boot(environment: self) if registration.provider.respond_to?(:boot)
          results << ProviderLifecycleResult.new(
            provider_name: registration.name,
            phase: :boot,
            status: :completed,
            service_names: provider_service_names(registration.name),
            interface_names: provider_interface_names(registration.name)
          )
        rescue StandardError => e
          results << ProviderLifecycleResult.new(
            provider_name: registration.name,
            phase: :boot,
            status: :failed,
            service_names: provider_service_names(registration.name),
            interface_names: provider_interface_names(registration.name),
            error: e
          )
          @provider_boot_report = ProviderLifecycleReport.new(phase: :boot, results: results)
          raise
        end

        @providers_booted = true
        @providers_shutdown = false
        @provider_boot_report = ProviderLifecycleReport.new(phase: :boot, results: results)
      end

      def shutdown_providers!
        results = if providers.empty?
                    []
                  elsif @providers_booted != true
                    providers.reverse_each.map do |registration|
                      ProviderLifecycleResult.new(
                        provider_name: registration.name,
                        phase: :shutdown,
                        status: :skipped,
                        service_names: provider_service_names(registration.name),
                        interface_names: provider_interface_names(registration.name)
                      )
                    end
                  else
                    shutdown_provider_results
                  end

        @providers_booted = false
        @providers_shutdown = true
        @provider_shutdown_report = ProviderLifecycleReport.new(phase: :shutdown, results: results)
      end

      def shutdown_provider_results
        results = []

        providers.reverse_each do |registration|
          registration.provider.shutdown(environment: self) if registration.provider.respond_to?(:shutdown)
          results << ProviderLifecycleResult.new(
            provider_name: registration.name,
            phase: :shutdown,
            status: :completed,
            service_names: provider_service_names(registration.name),
            interface_names: provider_interface_names(registration.name)
          )
        rescue StandardError => e
          results << ProviderLifecycleResult.new(
            provider_name: registration.name,
            phase: :shutdown,
            status: :failed,
            service_names: provider_service_names(registration.name),
            interface_names: provider_interface_names(registration.name),
            error: e
          )
          @provider_shutdown_report = ProviderLifecycleReport.new(phase: :shutdown, results: results)
          raise
        end

        results
      end

      def resolved_provider_services
        return @resolved_provider_services if defined?(@resolved_provider_services)

        resolve_providers!
        @resolved_provider_services
      end

      def resolved_provider_service_definitions
        return @resolved_provider_service_definitions if defined?(@resolved_provider_service_definitions)

        resolve_providers!
        @resolved_provider_service_definitions
      end

      def resolved_provider_interfaces
        return @resolved_provider_interfaces if defined?(@resolved_provider_interfaces)

        resolve_providers!
        @resolved_provider_interfaces
      end

      def resolved_provider_interface_definitions
        return @resolved_provider_interface_definitions if defined?(@resolved_provider_interface_definitions)

        resolve_providers!
        @resolved_provider_interface_definitions
      end

      def normalize_provider_entries(entries, registration:, definition_class:, values_map:, definitions_map:)
        return if entries.nil?

        entries.each do |name, value|
          definition =
            if value.is_a?(definition_class)
              value
            elsif value.is_a?(ServiceDefinition) && definition_class == ServiceDefinition
              value
            else
              definition_class.new(name: name, callable: value, source: registration.name)
            end

          values_map[definition.name] = definition.callable
          definitions_map[definition.name] = definition
        end
      end

      def execute_seam_action(seam_name:, action:, metadata:)
        yield
        SeamLifecycleResult.new(
          seam_name: seam_name,
          action: action,
          status: :completed,
          metadata: metadata
        )
      rescue StandardError => e
        result = SeamLifecycleResult.new(
          seam_name: seam_name,
          action: action,
          status: :failed,
          metadata: metadata,
          error: e
        )
        store_failed_seam_result(result)
        raise
      end

      def skipped_seam_result(seam_name:, action:, metadata:)
        SeamLifecycleResult.new(
          seam_name: seam_name,
          action: action,
          status: :skipped,
          metadata: metadata
        )
      end

      def skipped_seam_result_from_step(step)
        skipped_seam_result(
          seam_name: step.seam_name,
          action: step.action,
          metadata: step.metadata
        )
      end

      def planned_plan_step(name:, seam_name:, action:, metadata:)
        LifecyclePlanStep.new(
          name: name,
          seam_name: seam_name,
          action: action,
          status: :planned,
          metadata: metadata
        )
      end

      def skipped_plan_step(name:, seam_name:, action:, metadata:, reason:)
        LifecyclePlanStep.new(
          name: name,
          seam_name: seam_name,
          action: action,
          status: :skipped,
          metadata: metadata,
          reason: reason
        )
      end

      def build_boot_load_code_step(base_dir:, enabled:)
        metadata = {
          base_dir: base_dir.to_s,
          path_groups: profile.path_groups
        }
        return planned_plan_step(name: :load_code, seam_name: :loader, action: :load, metadata: metadata) if enabled

        skipped_plan_step(
          name: :load_code,
          seam_name: :loader,
          action: :load,
          metadata: metadata,
          reason: "load_code disabled"
        )
      end

      def build_boot_scheduler_step(enabled:)
        metadata = {
          scheduler: profile.scheduler_name,
          scheduled_jobs: profile.scheduled_job_names
        }
        return planned_plan_step(name: :start_scheduler, seam_name: :scheduler, action: :start, metadata: metadata) if enabled

        skipped_plan_step(
          name: :start_scheduler,
          seam_name: :scheduler,
          action: :start,
          metadata: metadata,
          reason: "start_scheduler disabled"
        )
      end

      def build_boot_host_step(enabled:)
        metadata = {
          host: profile.host_name
        }
        return planned_plan_step(name: :activate_transport, seam_name: :host, action: :activate_transport, metadata: metadata) if enabled

        skipped_plan_step(
          name: :activate_transport,
          seam_name: :host,
          action: :activate_transport,
          metadata: metadata,
          reason: "activate_transport disabled"
        )
      end

      def build_shutdown_host_step(enabled:)
        metadata = {
          host: profile.host_name,
          transport_activated: @transport_activated == true
        }
        unless enabled
          return skipped_plan_step(
            name: :deactivate_transport,
            seam_name: :host,
            action: :deactivate_transport,
            metadata: metadata,
            reason: "deactivate_transport disabled"
          )
        end

        unless @transport_activated == true
          return skipped_plan_step(
            name: :deactivate_transport,
            seam_name: :host,
            action: :deactivate_transport,
            metadata: metadata,
            reason: "transport not active"
          )
        end

        unless host_seam.respond_to?(:deactivate!)
          return skipped_plan_step(
            name: :deactivate_transport,
            seam_name: :host,
            action: :deactivate_transport,
            metadata: metadata,
            reason: "host seam does not support deactivate!"
          )
        end

        planned_plan_step(
          name: :deactivate_transport,
          seam_name: :host,
          action: :deactivate_transport,
          metadata: metadata
        )
      end

      def build_shutdown_scheduler_step(enabled:)
        metadata = {
          scheduler: profile.scheduler_name,
          scheduled_jobs: profile.scheduled_job_names,
          scheduler_running: @scheduler_running == true
        }
        unless enabled
          return skipped_plan_step(
            name: :stop_scheduler,
            seam_name: :scheduler,
            action: :stop,
            metadata: metadata,
            reason: "stop_scheduler disabled"
          )
        end

        unless @scheduler_running == true
          return skipped_plan_step(
            name: :stop_scheduler,
            seam_name: :scheduler,
            action: :stop,
            metadata: metadata,
            reason: "scheduler not running"
          )
        end

        planned_plan_step(
          name: :stop_scheduler,
          seam_name: :scheduler,
          action: :stop,
          metadata: metadata
        )
      end

      def build_shutdown_provider_step
        metadata = {
          providers: profile.provider_names,
          providers_booted: @providers_booted == true
        }
        if profile.provider_names.empty?
          return skipped_plan_step(
            name: :shutdown_providers,
            seam_name: :providers,
            action: :shutdown,
            metadata: metadata,
            reason: "no providers registered"
          )
        end

        unless @providers_booted == true
          return skipped_plan_step(
            name: :shutdown_providers,
            seam_name: :providers,
            action: :shutdown,
            metadata: metadata,
            reason: "providers not booted"
          )
        end

        planned_plan_step(
          name: :shutdown_providers,
          seam_name: :providers,
          action: :shutdown,
          metadata: metadata
        )
      end

      def store_failed_seam_result(result)
        case [result.seam_name, result.action]
        when %i[loader load]
          @loader_result = result
        when %i[scheduler start]
          @scheduler_start_result = result
        when %i[scheduler stop]
          @scheduler_stop_result = result
        when %i[host activate_transport]
          @host_activation_result = result
        when %i[host deactivate_transport]
          @host_deactivation_result = result
        end
      end

      def provider_service_names(provider_name)
        return [] unless defined?(@resolved_provider_service_definitions)

        @resolved_provider_service_definitions.values.select do |definition|
          definition.source == provider_name.to_sym
        end.map(&:name)
      end

      def provider_interface_names(provider_name)
        return [] unless defined?(@resolved_provider_interface_definitions)

        @resolved_provider_interface_definitions.values.select do |definition|
          definition.source == provider_name.to_sym
        end.map(&:name)
      end

      def provider_interface_entries(provider_name)
        return {} unless defined?(@resolved_provider_interface_definitions)

        @resolved_provider_interface_definitions.each_with_object({}) do |(name, definition), memo|
          memo[name] = definition.callable if definition.source == provider_name.to_sym
        end
      end

      def runtime_state
        {
          booted: booted?,
          code_loaded: !@loaded_base_dir.nil?,
          loaded_base_dir: @loaded_base_dir,
          loader: @loader_result&.to_h,
          application_load_report: @application_load_report&.to_h,
          providers_resolved: @providers_resolved == true,
          providers_booted: @providers_booted == true,
          providers_shutdown: @providers_shutdown == true,
          provider_resolution: @provider_resolution_report&.to_h,
          provider_boot: @provider_boot_report&.to_h,
          provider_shutdown: @provider_shutdown_report&.to_h,
          scheduler_running: @scheduler_running == true,
          scheduler_start: @scheduler_start_result&.to_h,
          scheduler_stop: @scheduler_stop_result&.to_h,
          transport_activated: @transport_activated == true,
          host_activation: @host_activation_result&.to_h,
          host_deactivation: @host_deactivation_result&.to_h,
          session_count: session_store.entries.size
        }
      end

      def normalize_compose_session_result(raw_result)
        if raw_result.is_a?(TransportResponse)
          [raw_result.result, raw_result.metadata]
        else
          [raw_result, {}]
        end
      end

      def normalize_collection_session_result(raw_result)
        if raw_result.is_a?(TransportResponse)
          [raw_result.result, raw_result.metadata]
        else
          [raw_result, {}]
        end
      end

      def normalize_load_report(result)
        return result if result.is_a?(ApplicationLoadReport)

        nil
      end
    end
  end
end
