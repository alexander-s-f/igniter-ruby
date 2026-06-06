# frozen_string_literal: true

module Playground
  module Tools
    # Pretty-prints records, facts, and causation chains as ASCII tables.
    module Viewer
      BAR = "─"
      H   = "│"

      def self.header(title, width: 60)
        pad = [(width - title.length - 2) / 2, 0].max
        line = BAR * width
        puts "\n#{line}"
        puts " #{' ' * pad}#{title}"
        puts "#{line}\n"
      end

      # Renders an array of hashes/structs as an aligned table.
      # +cols+ is an array of [label, accessor] pairs where accessor is a Symbol
      # (called on each row) or a Proc.
      def self.table(rows, cols:, title: nil, out: $stdout)
        header(title) if title

        if rows.empty?
          out.puts "  (empty)"
          return
        end

        # Resolve cell values
        data = rows.map do |row|
          cols.map do |_label, accessor|
            val = accessor.is_a?(Proc) ? accessor.call(row) : row.public_send(accessor)
            val.to_s
          end
        end

        widths = cols.each_with_index.map do |(_label, _), i|
          [cols[i][0].to_s.length, data.map { |r| r[i].length }.max].max
        end

        sep    = "+" + widths.map { |w| "-" * (w + 2) }.join("+") + "+"
        hdr    = "|" + cols.each_with_index.map { |(label, _), i| " #{label.to_s.ljust(widths[i])} " }.join("|") + "|"

        out.puts sep
        out.puts hdr
        out.puts sep
        data.each do |row|
          out.puts "|" + row.each_with_index.map { |cell, i| " #{cell.ljust(widths[i])} " }.join("|") + "|"
        end
        out.puts sep
      end

      # Renders an array of Durable Model Record instances.
      def self.records(records, schema_class, title: nil, out: $stdout)
        cols = [[:key, :key]] + schema_class._fields.keys.map { |f| [f, f] }
        table(records, cols: cols, title: title || schema_class.name, out: out)
      end

      # Renders a causation chain (array of hashes from causation_chain).
      def self.chain(entries, title: "Causation chain", out: $stdout)
        cols = [
          [:seq,       ->(e) { entries.index(e).to_s }],
          [:id,        ->(e) { e[:id][0, 8] + "…" }],
          [:causation, ->(e) { e[:causation] ? e[:causation][0, 8] + "…" : "(root)" }],
          [:value,     ->(e) { e[:value_hash] }],
          [:timestamp, ->(e) { format_ts(e[:timestamp]) }]
        ]
        table(entries, cols: cols, title: title, out: out)
      end

      # Renders a list of History events.
      def self.events(events, schema_class, title: nil, out: $stdout)
        cols = [
          [:fact_id,   ->(e) { e.fact_id[0, 8] + "…" }],
          [:timestamp, ->(e) { format_ts(e.timestamp) }]
        ] + schema_class._fields.keys.map { |f| [f, f] }
        table(events, cols: cols, title: title || "#{schema_class.name} events", out: out)
      end

      def self.format_ts(ts)
        return "-" unless ts
        t = Time.at(ts.to_f)
        t.strftime("%H:%M:%S.") + format("%03d", (t.usec / 1000))
      end
    end
  end
end
