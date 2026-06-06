# frozen_string_literal: true

module Igniter
  module Web
    module Arbre
      class MissingDependencyError < LoadError
      end

      module_function

      def available?
        !dependency.nil?
      rescue MissingDependencyError
        false
      end

      def component_class
        dependency.const_get(:Component)
      end

      def context_class
        dependency.const_get(:Context)
      end

      def ensure_available!
        dependency
      end

      def dependency
        return ::Arbre if defined?(::Arbre)

        require "arbre"
        ::Arbre
      rescue LoadError
        raise MissingDependencyError,
              "`igniter-web` now ships with a required `arbre` dependency. " \
              "Run bundle install to enable page and component rendering."
      end
    end
  end
end
