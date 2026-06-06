# frozen_string_literal: true

module Igniter
  module Web
    CompositionFinding = Struct.new(:severity, :code, :message, :suggestions, keyword_init: true) do
      def to_h
        {
          severity: severity,
          code: code,
          message: message,
          suggestions: suggestions || []
        }
      end
    end
  end
end
