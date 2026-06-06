# frozen_string_literal: true

module Igniter
  module DurableModel
    # Built-in audit history for explicit command-flow evidence export archives.
    class CommandFlowEvidenceArchive
      include Igniter::DurableModel::History

      history_name :command_flow_evidence_archives
      partition_key :owner

      field :owner
      field :view_name
      field :action, default: nil
      field :actor, default: nil
      field :export_id
      field :content_hash
      field :privacy
      field :status
      field :meaning_status
      field :profile_kind
      field :canonical_json
      field :diagnostics, default: []
      field :redactions, default: []
      field :metadata, default: {}
      field :store_fact_exposed, default: false
      field :value_hash_exposed, default: false
    end
  end
end
