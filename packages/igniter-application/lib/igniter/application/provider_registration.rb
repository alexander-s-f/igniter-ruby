# frozen_string_literal: true

module Igniter
  module Application
    ProviderRegistration = Struct.new(:name, :provider, keyword_init: true) do
      def initialize(name:, provider:)
        super(name: name.to_sym, provider: provider)
        freeze
      end

      def to_h
        {
          name: name,
          provider_class: provider.class.name || provider.class.inspect
        }
      end
    end
  end
end
