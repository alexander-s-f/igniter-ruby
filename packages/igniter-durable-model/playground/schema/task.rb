# frozen_string_literal: true

module Playground
  module Schema
    class Task
      include Igniter::DurableModel::Record

      store_name :tasks

      field :title
      field :status,   default: :open,   values: %i[open in_progress done]
      field :priority, default: :normal, values: %i[low normal high]
      field :assignee

      scope :open,          filters: { status: :open }
      scope :in_progress,   filters: { status: :in_progress }
      scope :done,          filters: { status: :done }
      scope :high_priority, filters: { priority: :high }
    end
  end
end
