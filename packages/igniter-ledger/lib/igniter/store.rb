# frozen_string_literal: true

module Igniter
  module Store
    NATIVE = false unless const_defined?(:NATIVE) # overwritten by native.rb when extension loads
  end
end

require_relative "store/native" # attempt to load Rust extension
require_relative "store/access_path"
require_relative "store/fact"              # Ruby Struct + Fact.from_h (always loaded)
require_relative "store/fact_log"          # Ruby FactLog + native all_facts patch
require_relative "store/wire_protocol"
require_relative "store/file_backend"      # Ruby FileBackend + native snapshot patch
require_relative "store/server_config"
require_relative "store/server_logger"
require_relative "store/subscription_registry"
require_relative "store/change_event"
require_relative "store/changefeed_buffer"
require_relative "store/network_backend"
require_relative "store/store_server"
require_relative "store/igniter_store"
require_relative "store/read_cache"
require_relative "store/schema_graph"
require_relative "store/protocol"
require_relative "store/http_adapter"
require_relative "store/tcp_adapter"
require_relative "store/codecs"
require_relative "store/segmented_file_backend"
require_relative "store/mcp_adapter"
require_relative "store/contractable_receipt_sink"
require_relative "store/tbackend_adapter_descriptor"

module Igniter
  module Store
    class << self
      def memory
        IgniterStore.new
      end

      def open(path)
        IgniterStore.open(path)
      end

      # Open (or create) a segmented WAL store at +root_dir+.
      # Facts from all stores are partitioned into per-store, per-time-bucket
      # segment files under root_dir/wal/.
      def segmented(root_dir, **opts)
        backend = SegmentedFileBackend.new(root_dir, **opts)
        store   = IgniterStore.new(backend: backend)
        backend.replay.each { |fact| store.__send__(:replay, fact) }
        store
      end

      def access_path(...)
        AccessPath.new(...)
      end
    end

    LedgerStore = IgniterStore unless const_defined?(:LedgerStore)
    LedgerServer = StoreServer unless const_defined?(:LedgerServer)
    LedgerNetworkBackend = NetworkBackend unless const_defined?(:LedgerNetworkBackend)
  end
end
