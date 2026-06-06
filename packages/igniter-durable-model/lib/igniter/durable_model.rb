# frozen_string_literal: true

require_relative "durable_model/record"
require_relative "durable_model/history"
require_relative "durable_model/command_activity"
require_relative "durable_model/command_flow_decision"
require_relative "durable_model/command_flow_evidence_archive"
require_relative "durable_model/receipts"
require_relative "durable_model/command_intent"
require_relative "durable_model/command_operation_plan"
require_relative "durable_model/command_activity_event"
require_relative "durable_model/command_policy_decision"
require_relative "durable_model/command_lifecycle"
require_relative "durable_model/command_flow"
require_relative "durable_model/command_flow_slice"
require_relative "durable_model/command_flow_monitor_result"
require_relative "durable_model/command_flow_view_descriptor"
require_relative "durable_model/command_flow_view"
require_relative "durable_model/command_flow_view_pin"
require_relative "durable_model/command_flow_decision_review"
require_relative "durable_model/command_flow_evidence_profile"
require_relative "durable_model/command_flow_evidence_export"
require_relative "durable_model/command_flow_evidence_export_verification"
require_relative "durable_model/store"

module Igniter
  module DurableModel
    def self.from_manifest(manifest, store: nil)
      shape = manifest.dig(:storage, :shape)
      case shape
      when :store then Record.from_manifest(manifest, store: store)
      when :history then History.from_manifest(manifest, store: store)
      else raise ArgumentError, "Unknown storage shape: #{shape.inspect}. Expected :store or :history"
      end
    end
  end
end
