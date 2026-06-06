# frozen_string_literal: true

require "json"

require_relative "hub/catalog_entry"
require_relative "hub/local_catalog"

module Igniter
  module Hub
    class << self
      def local_catalog(path)
        LocalCatalog.load(path)
      end
    end
  end
end
