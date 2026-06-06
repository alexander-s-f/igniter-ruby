# frozen_string_literal: true
# Demo 04 — Schema Version Coercion
# Simulates a field rename migration: v1 stored :title, v2 stores :name.
# The coercion hook transparently migrates v1 facts on the read path
# without touching the WAL.

require_relative "../setup"

include Playground

def run_04(store)
  v = Tools::Viewer
  v.header("04 · Schema Version Coercion")

  inner = Playground.inner_store(store)

  puts "\n▸ Writing a v1 fact (schema_version: 1, field :title)..."
  inner.write(store: :legacy_items, key: "li1",
              value: { title: "Old field name", active: true },
              schema_version: 1)

  puts "▸ Writing a v2 fact (schema_version: 2, field :name)..."
  inner.write(store: :legacy_items, key: "li2",
              value: { name: "New field name", active: true },
              schema_version: 2)

  puts "\n▸ Reading WITHOUT coercion:"
  puts "  li1: #{inner.read(store: :legacy_items, key: "li1").inspect}"
  puts "  li2: #{inner.read(store: :legacy_items, key: "li2").inspect}"

  puts "\n▸ Registering coercion: v1 :title → :name..."
  inner.register_coercion(:legacy_items) do |value, schema_version|
    next value if schema_version >= 2
    value.merge(name: value[:title]).tap { |h| h.delete(:title) }
  end

  puts "\n▸ Reading WITH coercion active:"
  puts "  li1 (was v1): #{inner.read(store: :legacy_items, key: "li1").inspect}"
  puts "  li2 (was v2): #{inner.read(store: :legacy_items, key: "li2").inspect}"

  puts "\n  → Both records now have :name regardless of schema_version."
  puts "  → The WAL is unchanged — coercion is read-path only."
end

run_04(Playground.store) if __FILE__ == $PROGRAM_NAME
