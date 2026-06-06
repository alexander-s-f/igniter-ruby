# frozen_string_literal: true

module Igniter
  module Cluster
    class MemoryIncidentRegistry
      def initialize(entries: {})
        @entries = {}
        @actions = {}
        @next_sequence = 0
        @next_action_sequence = 0
        @mutex = Mutex.new

        entries.each_value { |entry| write(entry) }
      end

      def record(report, metadata: {})
        @mutex.synchronize do
          @next_sequence += 1
          write_unlocked(IncidentEntry.from_report(report, sequence: @next_sequence, metadata: metadata))
        end
      end

      def write(entry)
        @mutex.synchronize do
          write_unlocked(entry)
        end
      end

      def fetch(id)
        @mutex.synchronize do
          @entries.fetch(id.to_s)
        end
      end

      def entries
        @mutex.synchronize do
          @entries.values.sort_by(&:sequence)
        end
      end

      def record_action(incident, kind:, status: :recorded, actor: nil, note: nil, metadata: {})
        @mutex.synchronize do
          entry = resolve_entry_unlocked(incident)
          @next_action_sequence += 1
          action = IncidentAction.new(
            incident_key: entry.incident_key,
            sequence: @next_action_sequence,
            kind: kind,
            status: status,
            actor: actor,
            note: note,
            metadata: metadata.merge(
              incident_id: entry.id,
              incident_kind: entry.incident.kind,
              incident_resolution: entry.resolution
            ),
            explanation: DecisionExplanation.new(
              code: :"incident_#{kind}",
              message: "recorded #{kind} for #{entry.incident.kind} incident",
              metadata: {
                incident_id: entry.id,
                incident_key: entry.incident_key
              }
            )
          )
          @actions[action.id] = action
          action
        end
      end

      def actions(incident = nil)
        @mutex.synchronize do
          selected = if incident.nil?
                       @actions.values
                     else
                       key = resolve_incident_key_unlocked(incident)
                       @actions.values.select { |action| action.incident_key == key }
                     end
          selected.sort_by(&:sequence)
        end
      end

      def workflow(incident)
        @mutex.synchronize do
          key = resolve_incident_key_unlocked(incident)
          build_workflow_unlocked(key)
        end
      end

      def workflows
        @mutex.synchronize do
          @entries.values.map(&:incident_key).uniq.sort.map { |key| build_workflow_unlocked(key) }
        end
      end

      def active_set
        snapshot = entries
        latest_entries = snapshot.group_by(&:incident_key).values.map { |group| group.max_by(&:sequence) }
        active_entries = latest_entries.select do |entry|
          entry.active? && build_workflow_for_snapshot(entry.incident_key, snapshot).active?
        end

        ActiveIncidentSet.new(
          entries: active_entries,
          metadata: {
            registry: :memory,
            total_entries: snapshot.length
          }
        )
      end

      private

      def write_unlocked(entry)
        @entries[entry.id] = entry
        @next_sequence = [@next_sequence, entry.sequence].max
        entry
      end

      def resolve_entry_unlocked(incident)
        return incident if incident.is_a?(IncidentEntry)

        ref = incident.to_s
        return @entries.fetch(ref) if @entries.key?(ref)

        entries_for_key = @entries.values.select { |entry| entry.incident_key == ref }
        return entries_for_key.max_by(&:sequence) unless entries_for_key.empty?

        raise KeyError, "unknown incident #{incident.inspect}"
      end

      def resolve_incident_key_unlocked(incident)
        return incident.incident_key if incident.respond_to?(:incident_key)

        resolve_entry_unlocked(incident).incident_key
      rescue KeyError
        incident.to_s
      end

      def build_workflow_unlocked(incident_key)
        workflow_entries = @entries.values.select { |entry| entry.incident_key == incident_key }
        workflow_actions = @actions.values.select { |action| action.incident_key == incident_key }
        IncidentWorkflow.new(
          incident_key: incident_key,
          entries: workflow_entries,
          actions: workflow_actions,
          metadata: {
            registry: :memory,
            latest_entry_id: workflow_entries.max_by(&:sequence)&.id
          }
        )
      end

      def build_workflow_for_snapshot(incident_key, snapshot)
        workflow_entries = snapshot.select { |entry| entry.incident_key == incident_key }
        workflow_actions = @actions.values.select { |action| action.incident_key == incident_key }
        IncidentWorkflow.new(
          incident_key: incident_key,
          entries: workflow_entries,
          actions: workflow_actions,
          metadata: {
            registry: :memory,
            latest_entry_id: workflow_entries.max_by(&:sequence)&.id
          }
        )
      end
    end
  end
end
