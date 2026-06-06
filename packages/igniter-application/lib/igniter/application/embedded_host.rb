# frozen_string_literal: true

module Igniter
  module Application
    class EmbeddedHost
      def activate!(environment:)
        environment
      end

      def deactivate!(environment:)
        environment
      end

      def start(environment:)
        environment.snapshot
      end

      def rack_app(_environment:)
        ->(_env) { [200, { "content-type" => "text/plain" }, ["Igniter::Application embedded host"]] }
      end
    end
  end
end
