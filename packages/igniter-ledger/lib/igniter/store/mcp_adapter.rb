# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "set"
require "uri"

module Igniter
  module Store
    # Read-only MCP adapter over Store Open Protocol.
    #
    # Every tool call lowers to a Protocol::Interpreter method or a named
    # protocol metadata view.  The adapter never touches backends directly,
    # never executes Igniter contracts, and never evaluates Ruby DSL.
    #
    # Usage — embedded (local store):
    #
    #   store   = Igniter::Store.segmented(root_dir)
    #   adapter = Igniter::Store::MCPAdapter.new(store)
    #   result  = adapter.call_tool(:query, store: "tasks", where: {}, limit: 50)
    #
    # Usage — wrap an existing Interpreter:
    #
    #   adapter = Igniter::Store::MCPAdapter.new(proto)  # proto = Protocol::Interpreter
    #
    # Usage — remote StoreServer /v1/dispatch:
    #
    #   adapter = Igniter::Store::MCPAdapter.remote("http://127.0.0.1:7300/v1/dispatch")
    #
    # Every response includes:
    #   schema_version, request_id, source_protocol_op, status, result | error
    #
    # Mutating tools (write_fact, register_descriptor, compact, checkpoint) are
    # disabled by default and require an explicit :enabled_tools list.
    class MCPAdapter
      SCHEMA_VERSION = 1

      READ_TOOLS = %i[
        metadata_snapshot
        descriptor_snapshot
        observability_snapshot
        read
        query
        resolve
        causation_chain
        lineage
        fact_ref
        replay
        sync_profile
        storage_stats
        segment_manifest
        compaction_activity
      ].freeze

      TOOL_TO_OP = {
        metadata_snapshot:      :metadata_snapshot,
        descriptor_snapshot:    :descriptor_snapshot,
        observability_snapshot: :observability_snapshot,
        read:                   :read,
        query:                  :query,
        resolve:                :resolve,
        causation_chain:        :causation_chain,
        lineage:                :lineage,
        fact_ref:               :fact_ref,
        replay:                 :replay,
        sync_profile:           :sync_hub_profile,
        storage_stats:          :storage_stats,
        segment_manifest:       :segment_manifest,
        compaction_activity:    :compaction_activity
      }.freeze

      class RemoteDispatch
        def initialize(endpoint)
          @uri = normalize_endpoint(endpoint)
        end

        def dispatch(op:, packet:, request_id:)
          envelope = {
            protocol:       :igniter_store,
            schema_version: SCHEMA_VERSION,
            request_id:     request_id,
            op:             op,
            packet:         packet
          }

          request = Net::HTTP::Post.new(@uri)
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(envelope)

          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = @uri.scheme == "https"
          response = http.request(request)
          unless response.code.to_i.between?(200, 299)
            raise "HTTP #{@uri} returned #{response.code}"
          end

          JSON.parse(response.body, symbolize_names: true)
        end

        private

        def normalize_endpoint(endpoint)
          uri = URI(endpoint.to_s)
          uri.path = "/v1/dispatch" if uri.path.nil? || uri.path.empty? || uri.path == "/"
          uri
        end
      end

      def self.remote(endpoint, enabled_tools: READ_TOOLS)
        new(RemoteDispatch.new(endpoint), enabled_tools: enabled_tools)
      end

      # +interpreter_or_store+ — Protocol::Interpreter, IgniterStore, or a store
      #   returned by Igniter::Store.segmented / Igniter::Store.memory.
      # +enabled_tools+        — Array of tool name Symbols. Defaults to READ_TOOLS.
      def initialize(interpreter_or_store, enabled_tools: READ_TOOLS)
        @interpreter = case interpreter_or_store
                       when Protocol::Interpreter
                         interpreter_or_store
                       when IgniterStore
                         Protocol::Interpreter.new(interpreter_or_store)
                       when RemoteDispatch
                         interpreter_or_store
                       else
                         raise ArgumentError,
                               "MCPAdapter expects a Protocol::Interpreter, IgniterStore, or RemoteDispatch, " \
                               "got #{interpreter_or_store.class}"
                       end
        @remote = interpreter_or_store.is_a?(RemoteDispatch)
        @enabled = enabled_tools.map(&:to_sym).to_set
      end

      # Returns an Array of tool schema Hashes (name + description + input_schema).
      def tool_list
        READ_TOOLS.select { |t| @enabled.include?(t) }.map { |t| tool_schema(t) }
      end

      # Call a named tool with an arguments Hash (symbol or string keys).
      # Returns a response Hash with schema_version, request_id, status, etc.
      # Never raises — errors are captured into the response envelope.
      def call_tool(name, arguments = {})
        tool = nil
        req = nil
        tool = name.to_sym
        args = arguments.transform_keys(&:to_sym)
        req  = args.delete(:request_id) || generate_request_id

        unless @enabled.include?(tool)
          return error_response(tool, req, "Tool #{tool.inspect} is not enabled")
        end

        result = dispatch(tool, args, request_id: req)
        ok_response(tool, req, result)
      rescue ArgumentError => e
        error_response(tool, req || generate_request_id, e.message)
      rescue StandardError => e
        error_response(tool, req || generate_request_id, "Internal error: #{e.message}")
      end

      private

      def dispatch(name, args, request_id:)
        return remote_dispatch(name, args, request_id: request_id) if @remote

        case name
        when :metadata_snapshot
          @interpreter.metadata_snapshot

        when :descriptor_snapshot
          @interpreter.descriptor_snapshot

        when :observability_snapshot
          @interpreter.observability_snapshot

        when :read
          @interpreter.read(
            store: args.fetch(:store),
            key:   args.fetch(:key),
            as_of: args[:as_of]
          )

        when :query
          raise ArgumentError, "query: requires limit:" unless args.key?(:limit)
          items = @interpreter.query(
            store:  args.fetch(:store),
            where:  args.fetch(:where, {}),
            order:  args[:order],
            limit:  args[:limit].to_i,
            as_of:  args[:as_of]
          )
          items.map { |item| item[:value] }

        when :resolve
          @interpreter.resolve(
            args.fetch(:relation).to_sym,
            from:  args.fetch(:from),
            as_of: args[:as_of]
          )

        when :causation_chain
          chain = @interpreter.causation_chain(
            store: args.fetch(:store),
            key:   args.fetch(:key)
          )
          { chain: chain, count: chain.size }

        when :lineage
          @interpreter.lineage(
            store: args.fetch(:store),
            key:   args.fetch(:key)
          )

        when :fact_ref
          ref = @interpreter.fact_ref(args.fetch(:fact_id))
          { found: !ref.nil?, ref: ref }

        when :replay
          unless args[:limit] || args[:store] || args[:from]
            raise ArgumentError, "replay: requires at least one bounding argument (limit:, store:, or from:)"
          end
          filter = args[:store] ? { store: args[:store] } : args[:filter]
          facts  = @interpreter.replay(from: args[:from], to: args[:to], filter: filter)
          facts  = facts.first(args[:limit].to_i) if args[:limit]
          { facts: facts, count: facts.size }

        when :sync_profile
          @interpreter.sync_hub_profile(
            as_of:  args[:as_of],
            cursor: args[:cursor],
            stores: args[:stores]
          )

        when :storage_stats
          @interpreter.storage_stats(store: args[:store])

        when :segment_manifest
          @interpreter.segment_manifest(store: args[:store])

        when :compaction_activity
          @interpreter.compaction_activity(
            store: args[:store],
            kind:  args[:kind],
            since: args[:since],
            limit: args[:limit]
          )
        end
      end

      def remote_dispatch(name, args, request_id:)
        packet = packet_for(name, args)
        op = TOOL_TO_OP.fetch(name)
        response = @interpreter.dispatch(op: op, packet: packet, request_id: request_id)
        status = response[:status]&.to_sym
        raise "remote dispatch #{op.inspect} failed: #{response[:error]}" unless status == :ok

        normalize_wire_result(name, response[:result])
      end

      def packet_for(name, args)
        case name
        when :metadata_snapshot, :descriptor_snapshot, :observability_snapshot
          {}
        when :read
          { store: args.fetch(:store), key: args.fetch(:key), as_of: args[:as_of] }
        when :query
          raise ArgumentError, "query: requires limit:" unless args.key?(:limit)
          { store: args.fetch(:store), where: args.fetch(:where, {}),
            order: args[:order], limit: args[:limit].to_i, as_of: args[:as_of] }
        when :resolve
          { relation: args.fetch(:relation), from: args.fetch(:from), as_of: args[:as_of] }
        when :causation_chain, :lineage
          { store: args.fetch(:store), key: args.fetch(:key) }
        when :fact_ref
          { fact_id: args.fetch(:fact_id) }
        when :replay
          unless args[:limit] || args[:store] || args[:from]
            raise ArgumentError, "replay: requires at least one bounding argument (limit:, store:, or from:)"
          end
          packet = { from: args[:from], to: args[:to], filter: args[:filter] }
          packet[:filter] = { store: args[:store] } if args[:store]
          packet[:limit] = args[:limit].to_i if args[:limit]
          packet
        when :sync_profile
          { as_of: args[:as_of], cursor: args[:cursor], stores: args[:stores] }
        when :storage_stats, :segment_manifest
          { store: args[:store] }
        when :compaction_activity
          { store: args[:store], kind: args[:kind], since: args[:since], limit: args[:limit] }
        else
          {}
        end.compact
      end

      def normalize_wire_result(name, result)
        case name
        when :read
          result[:value]
        when :query, :resolve
          result[:results]
        when :replay
          facts = result[:facts]
          count = result[:count]
          { facts: facts, count: count }
        else
          result
        end
      end

      def ok_response(tool, request_id, result)
        {
          schema_version:     SCHEMA_VERSION,
          request_id:         request_id,
          source_protocol_op: TOOL_TO_OP[tool],
          status:             :ok,
          result:             result
        }
      end

      def error_response(tool, request_id, message)
        {
          schema_version:     SCHEMA_VERSION,
          request_id:         request_id,
          source_protocol_op: TOOL_TO_OP[tool],
          status:             :error,
          error:              message
        }
      end

      def generate_request_id
        "mcp_#{SecureRandom.hex(8)}"
      end

      def tool_schema(name)
        {
          name:        name.to_s,
          description: tool_description(name),
          input_schema: tool_input_schema(name)
        }
      end

      def tool_description(name)
        {
          metadata_snapshot:      "Return the full protocol registry metadata snapshot.",
          descriptor_snapshot:    "Return registered descriptors grouped by kind.",
          observability_snapshot: "Return the canonical observability snapshot: status, alerts, storage.",
          read:                   "Read the current (or as_of) value for one key.",
          query:                  "Query a bounded store view with optional where/order/limit/as_of.",
          resolve:                "Resolve a registered relation from a source key.",
          causation_chain:        "Return the compact causation chain for a store/key.",
          lineage:                "Return read-only lineage proof metadata for a store/key.",
          fact_ref:               "Return compact metadata for a fact id without exposing fact value.",
          replay:                 "Replay bounded facts by store, time range, or limit.",
          sync_profile:           "Return a sync hub profile (facts + descriptors + cursor).",
          storage_stats:          "Return aggregate storage statistics for one or all stores.",
          segment_manifest:       "Return per-segment storage manifest for one or all stores.",
          compaction_activity:    "Return normalized compaction lifecycle activity (retention compact, exact prune, segment purge)."
        }.fetch(name, name.to_s)
      end

      def tool_input_schema(name)
        case name
        when :read
          { type: "object", required: ["store", "key"],
            properties: { store: { type: "string" }, key: { type: "string" },
                          as_of: { type: "number" } } }
        when :query
          { type: "object", required: ["store", "limit"],
            properties: { store: { type: "string" }, where: { type: "object" },
                          order: { type: "string" }, limit: { type: "integer" },
                          as_of: { type: "number" } } }
        when :resolve
          { type: "object", required: ["relation", "from"],
            properties: { relation: { type: "string" }, from: { type: "string" },
                          as_of: { type: "number" } } }
        when :causation_chain, :lineage
          { type: "object", required: ["store", "key"],
            properties: { store: { type: "string" }, key: { type: "string" } } }
        when :fact_ref
          { type: "object", required: ["fact_id"],
            properties: { fact_id: { type: "string" } } }
        when :replay
          { type: "object",
            properties: { store: { type: "string" }, from: { type: "number" },
                          to: { type: "number" }, limit: { type: "integer" } } }
        when :storage_stats, :segment_manifest
          { type: "object",
            properties: { store: { type: "string" } } }
        when :sync_profile
          { type: "object",
            properties: { stores: { type: "array" }, cursor: { type: "object" },
                          as_of: { type: "number" } } }
        when :compaction_activity
          { type: "object",
            properties: { store: { type: "string" }, kind: { type: "string" },
                          since: { type: "number" }, limit: { type: "integer" } } }
        else
          { type: "object", properties: {} }
        end
      end
    end
  end
end
