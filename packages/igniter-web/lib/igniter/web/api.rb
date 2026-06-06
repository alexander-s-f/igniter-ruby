# frozen_string_literal: true

module Igniter
  module Web
    class Api
      Endpoint = Struct.new(:kind, :verb, :path, :target, :metadata, keyword_init: true)

      attr_reader :endpoints

      def initialize
        @endpoints = []
      end

      def draw(&block)
        instance_eval(&block) if block
        self
      end

      def command(path, to:, via: :post, **metadata)
        register_endpoint(:command, path, to, via, metadata)
      end

      def query(path, to:, via: :get, **metadata)
        register_endpoint(:query, path, to, via, metadata)
      end

      def stream(path, to:, via: :get, **metadata)
        register_endpoint(:stream, path, to, via, metadata)
      end

      def webhook(path, to:, via: :post, **metadata)
        register_endpoint(:webhook, path, to, via, metadata)
      end

      private

      def register_endpoint(kind, path, target, verb, metadata)
        @endpoints << Endpoint.new(
          kind: kind,
          verb: verb.to_sym,
          path: path,
          target: target,
          metadata: metadata.freeze
        )
        self
      end
    end
  end
end
