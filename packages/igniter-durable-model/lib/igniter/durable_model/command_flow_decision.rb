# frozen_string_literal: true

module Igniter
  module DurableModel
    # Built-in audit history for app-safe command-flow view decisions.
    class CommandFlowDecision
      include Igniter::DurableModel::History

      history_name :command_flow_decisions
      partition_key :owner

      field :owner
      field :view_name
      field :action
      field :actor, default: nil
      field :status
      field :meaning_status
      field :receipt_id
      field :decision_receipt_id, default: nil
      field :horizon, default: {}
      field :capabilities, default: []
      field :missing_capabilities, default: []
      field :view_status, default: nil
      field :monitor_status, default: nil
      field :summary, default: {}
      field :errors, default: []
      field :warnings, default: []
      field :metadata, default: {}
      field :store_fact_exposed, default: false
      field :value_hash_exposed, default: false
    end
  end
end
