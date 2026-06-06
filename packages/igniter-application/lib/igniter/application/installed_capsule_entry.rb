# frozen_string_literal: true

module Igniter
  module Application
    InstalledCapsuleEntry = Struct.new(
      :name, :status, :source, :version, :complete, :valid, :committed,
      :receipt, :metadata, :installed_at,
      keyword_init: true
    ) do
      def initialize(name:, receipt:, source: nil, version: nil, metadata: {}, installed_at: nil)
        receipt_payload = receipt.to_h
        super(
          name: name.to_sym,
          status: receipt_payload.fetch(:complete, false) ? :installed : :blocked,
          source: source,
          version: version,
          complete: receipt_payload.fetch(:complete, false),
          valid: receipt_payload.fetch(:valid, false),
          committed: receipt_payload.fetch(:committed, false),
          receipt: receipt_payload.freeze,
          metadata: metadata.dup.freeze,
          installed_at: installed_at
        )
        freeze
      end

      def installed?
        status == :installed
      end

      def to_h
        {
          name: name,
          status: status,
          source: source,
          version: version,
          complete: complete,
          valid: valid,
          committed: committed,
          receipt: receipt,
          metadata: metadata.dup,
          installed_at: installed_at
        }.compact
      end
    end
  end
end
