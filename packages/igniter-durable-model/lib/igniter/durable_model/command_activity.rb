# frozen_string_literal: true

module Igniter
  module DurableModel
    # Built-in audit history for app-safe command activity summaries.
    class CommandActivity
      include Igniter::DurableModel::History

      history_name :command_activity
      partition_key :owner

      field :owner
      field :command
      field :subject_key
      field :operation
      field :status
      field :intent_status
      field :plan_status
      field :target, default: nil
      field :errors, default: []
      field :warnings, default: []
      field :metadata, default: {}
      field :store_fact_exposed, default: false
      field :value_hash_exposed, default: false
      field :execution_allowed, default: false
    end
  end
end
