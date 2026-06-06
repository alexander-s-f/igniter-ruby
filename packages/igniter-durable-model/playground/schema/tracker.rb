# frozen_string_literal: true

module Playground
  module Schema
    class TrackerEntry
      include Igniter::DurableModel::History

      history_name :tracker_entries
      partition_key :tracker_id

      field :tracker_id
      field :value
      field :unit,  default: "count"
      field :note
    end
  end
end
