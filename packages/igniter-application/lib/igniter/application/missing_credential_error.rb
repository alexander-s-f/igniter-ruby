# frozen_string_literal: true

module Igniter
  module Application
    class MissingCredentialError < KeyError
      attr_reader :name, :env

      def initialize(name, env: nil)
        @name = name.to_sym
        @env = env
        super(build_message)
      end

      private

      def build_message
        return "credential #{name.inspect} is missing" if env.nil?

        "credential #{name.inspect} is missing; set #{env}"
      end
    end
  end
end
