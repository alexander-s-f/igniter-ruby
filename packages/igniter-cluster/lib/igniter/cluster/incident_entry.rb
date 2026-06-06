# frozen_string_literal: true

module Igniter
  module Cluster
    class IncidentEntry
      attr_reader :id, :sequence, :incident_key, :plan_kind, :status, :resolution,
                  :incident, :recovery_timeline, :metadata, :explanation

      def self.from_report(report, sequence:, metadata: {})
        incident = report.incident
        raise ArgumentError, "plan execution report does not include incident artifacts" if incident.nil?

        resolution = resolve_resolution(report.recovery_timeline)
        details = metadata.merge(
          sequence: sequence,
          plan_kind: report.plan_kind,
          report_status: report.status,
          incident_kind: incident.kind,
          resolution: resolution
        )

        new(
          id: build_id(incident, sequence),
          sequence: sequence,
          incident_key: build_incident_key(incident),
          plan_kind: report.plan_kind,
          status: report.status,
          resolution: resolution,
          incident: incident,
          recovery_timeline: report.recovery_timeline,
          metadata: details,
          explanation: DecisionExplanation.new(
            code: :incident_entry,
            message: "recorded #{incident.kind} incident entry",
            metadata: details
          )
        )
      end

      def self.resolve_resolution(recovery_timeline)
        recovery_timeline&.event_log&.events&.last&.status&.to_sym || :unknown
      end

      def self.build_id(incident, sequence)
        "#{incident.kind}/#{sequence}"
      end

      def self.build_incident_key(incident)
        [
          incident.kind,
          Array(incident.targets).sort.join(","),
          Array(incident.source_names).sort.join(","),
          Array(incident.destination_names).sort.join(","),
          Array(incident.owner_names).sort.join(",")
        ].join("|")
      end

      def initialize(id:, sequence:, incident_key:, plan_kind:, status:, resolution:, incident:, recovery_timeline: nil,
                     metadata: {}, explanation: nil)
        @id = id.to_s.freeze
        @sequence = Integer(sequence)
        @incident_key = incident_key.to_s.freeze
        @plan_kind = plan_kind.to_sym
        @status = status.to_sym
        @resolution = resolution.to_sym
        @incident = incident
        @recovery_timeline = recovery_timeline
        @metadata = metadata.dup.freeze
        @explanation = DecisionExplanation.normalize(
          explanation,
          default_code: :incident_entry,
          metadata: @metadata
        )
        freeze
      end

      def active?
        !%i[recovered stable].include?(resolution)
      end

      def to_h
        {
          id: id,
          sequence: sequence,
          incident_key: incident_key,
          plan_kind: plan_kind,
          status: status,
          resolution: resolution,
          active: active?,
          incident: incident.to_h,
          recovery_timeline: recovery_timeline&.to_h,
          metadata: metadata.dup,
          explanation: explanation&.to_h
        }
      end
    end
  end
end
