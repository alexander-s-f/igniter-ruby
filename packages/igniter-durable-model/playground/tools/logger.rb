# frozen_string_literal: true

module Playground
  module Tools
    # Wraps a DurableModel::Store and logs timing + call info for each operation.
    # Also accumulates a structured call log for post-run analysis.
    #
    # Usage:
    #   raw   = Playground.store
    #   store = Playground::Tools::Logger.new(raw)
    #   store.write(Task, key: "t1", title: "Demo")   # prints timing
    #   store.call_log                                 # structured history
    class Logger
      METHODS = %i[write read scope append replay causation_chain on_scope register].freeze

      attr_reader :call_log

      def initialize(store, out: $stdout, color: true)
        @store    = store
        @out      = out
        @color    = color
        @call_log = []
      end

      METHODS.each do |meth|
        define_method(meth) do |*args, **kwargs, &block|
          timed(meth, args, kwargs) { @store.public_send(meth, *args, **kwargs, &block) }
        end
      end

      def method_missing(name, *args, **kwargs, &block)
        @store.public_send(name, *args, **kwargs, &block)
      end

      def respond_to_missing?(name, include_private = false)
        @store.respond_to?(name, include_private) || super
      end

      # Print a summary table of all recorded calls.
      def summary(out: @out)
        return out.puts "(no calls recorded)" if @call_log.empty?

        out.puts "\n#{"─" * 52}"
        out.puts " Call log summary (#{@call_log.size} calls)"
        out.puts "#{"─" * 52}"
        by_op = @call_log.group_by { |e| e[:op] }
        by_op.each do |op, calls|
          total  = calls.sum { |c| c[:elapsed_ms] }
          avg    = (total / calls.size).round(3)
          out.puts "  %-18s  %3d calls  total %7.3fms  avg %6.3fms" % [op, calls.size, total, avg]
        end
        out.puts "#{"─" * 52}"
      end

      private

      OP_COLORS = {
        write:   "\e[33m", # yellow
        read:    "\e[36m", # cyan
        scope:   "\e[34m", # blue
        append:  "\e[35m", # magenta
        replay:  "\e[35m",
        default: "\e[37m"  # white
      }.freeze
      RESET = "\e[0m"

      def timed(op, args, kwargs)
        t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        ms     = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000).round(3)

        entry = { op: op, elapsed_ms: ms, args: args, kwargs: kwargs.keys }
        @call_log << entry

        label  = "[#{op.to_s.upcase.ljust(10)}]"
        detail = call_detail(op, args, kwargs, result)
        color  = @color ? (OP_COLORS[op] || OP_COLORS[:default]) : ""
        reset  = @color ? RESET : ""

        @out.puts "#{color}#{label}#{reset} #{format('%7.3f', ms)}ms  #{detail}"
        result
      end

      def call_detail(op, args, kwargs, result)
        schema = args.first
        name   = schema.respond_to?(:store_name) ? schema.store_name : schema.inspect

        case op
        when :write
          "#{name} key=#{kwargs[:key]}"
        when :read
          val = result ? result.to_h.inspect[0, 60] : "nil"
          "#{name} key=#{kwargs[:key]}  → #{val}"
        when :scope
          "#{name} :#{args[1]}  → #{result.size} records"
        when :append
          "#{name}"
        when :replay
          "#{name}  → #{result.size} events"
        else
          name.to_s
        end
      end
    end
  end
end
