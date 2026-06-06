# frozen_string_literal: true

module Igniter
  module Application
    class Provider
      def services(_environment:)
        {}
      end

      def interfaces(_environment:)
        {}
      end

      def boot(_environment:); end

      def shutdown(_environment:); end
    end
  end
end
