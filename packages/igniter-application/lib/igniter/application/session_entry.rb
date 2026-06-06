# frozen_string_literal: true

require "time"

module Igniter
  module Application
    class SessionEntry
      attr_reader :id, :kind, :status, :metadata, :payload, :created_at, :updated_at

      def initialize(id:, kind:, status:, metadata: {}, payload: {}, created_at: Time.now.utc, updated_at: created_at)
        @id = id.to_s
        @kind = kind.to_sym
        @status = status.to_sym
        @metadata = metadata.dup.freeze
        @payload = payload.dup.freeze
        @created_at = created_at
        @updated_at = updated_at
        freeze
      end

      def with_update(status: self.status, metadata: self.metadata, payload: self.payload, updated_at: Time.now.utc)
        self.class.new(
          id: id,
          kind: kind,
          status: status,
          metadata: metadata,
          payload: payload,
          created_at: created_at,
          updated_at: updated_at
        )
      end

      def to_h
        {
          id: id,
          kind: kind,
          status: status,
          metadata: metadata.dup,
          payload: payload.dup,
          created_at: created_at.utc.iso8601,
          updated_at: updated_at.utc.iso8601
        }
      end
    end
  end
end
