# frozen_string_literal: true

require "spec_helper"
require "igniter-frontend"
require "igniter-schema-rendering"
require "igniter/sdk/data"

RSpec.describe "Igniter::SchemaRendering runtime" do
  before do
    Igniter::Data.default_store = Igniter::Data::Stores::InMemory.new
  end

  after do
    Igniter::Data.reset!
  end

  let(:schema_payload) do
    {
      id: "training-checkin",
      version: 1,
      kind: "page",
      title: "Daily Training Check-in",
      actions: {
        submit_checkin: {
          type: "contract",
          target: "Companion::Dashboard::TrainingCheckinSubmissionContract",
          method: "post",
          path: "/views/training-checkin/submissions"
        }
      },
      layout: {
        type: "stack",
        children: [
          { type: "heading", level: 1, text: "Daily Training Check-in" },
          { type: "text", text: "A schema-driven page." },
          { type: "notice", message: "Bring context from your latest workout.", tone: "info" },
          {
            type: "form",
            action: "submit_checkin",
            children: [
              {
                type: "fieldset",
                legend: "Session",
                description: "Core daily inputs.",
                children: [
                  { type: "input", name: "duration_minutes", label: "Duration", required: true, value_type: "integer" },
                  {
                    type: "select",
                    name: "mood",
                    label: "Mood",
                    selected: "good",
                    options: [
                      { label: "Great", value: "great" },
                      { label: "Good", value: "good" }
                    ]
                  },
                  { type: "checkbox", name: "share", label: "Share with coach", checked: true, value_type: "boolean" },
                  { type: "text", text: "Double-check duration before submitting." }
                ]
              },
              {
                type: "actions",
                children: [
                  { type: "submit", label: "Save" }
                ]
              }
            ]
          }
        ]
      }
    }
  end

  it "validates and stores schemas" do
    store = Igniter::SchemaRendering::Store.new
    schema = store.put(schema_payload)

    expect(schema).to be_a(Igniter::SchemaRendering::Schema)
    expect(store.fetch("training-checkin").title).to eq("Daily Training Check-in")
  end

  it "patches schemas and increments version" do
    store = Igniter::SchemaRendering::Store.new
    store.put(schema_payload)

    schema = store.patch(
      "training-checkin",
      patch: {
        title: "Updated Check-in",
        meta: { audience: "public" }
      }
    )

    expect(schema.version).to eq(2)
    expect(schema.title).to eq("Updated Check-in")
    expect(schema.meta).to include("audience" => "public")
  end

  it "replaces arrays when patching nested layout nodes" do
    store = Igniter::SchemaRendering::Store.new
    store.put(schema_payload)

    schema = store.patch(
      "training-checkin",
      patch: {
        layout: {
          children: [
            { type: "heading", level: 1, text: "Short Form" }
          ]
        }
      }
    )

    expect(schema.layout.fetch("children").size).to eq(1)
    expect(schema.layout.fetch("children").first.fetch("text")).to eq("Short Form")
  end

  it "renders a schema into HTML" do
    html = Igniter::SchemaRendering::Renderer.render(schema: schema_payload)

    expect(html).to include("<!DOCTYPE html>")
    expect(html).to include("Daily Training Check-in")
    expect(html).to include("Schema Page")
    expect(html).to include("view-stack")
    expect(html).to include("@tailwindcss/browser@4")
    expect(html).to include("font-display")
    expect(html).to include("Bring context from your latest workout.")
    expect(html).to include('action="/views/training-checkin/submissions"')
    expect(html).to include("<fieldset")
    expect(html).to include("Session")
    expect(html).to include("Core daily inputs.")
    expect(html).to include('name="_action"')
    expect(html).to include('name="duration_minutes"')
    expect(html).to include('name="mood"')
    expect(html).to include("Share with coach")
    expect(html).to include(">Save</button>")
  end

  it "normalizes typed submission payloads from a form action" do
    schema = Igniter::SchemaRendering::Schema.load(schema_payload)
    normalized = Igniter::SchemaRendering::SubmissionNormalizer.new(schema).normalize(
      {
        "_action" => "submit_checkin",
        "duration_minutes" => "45",
        "mood" => "great",
        "share" => "1"
      },
      action_id: "submit_checkin"
    )

    expect(normalized).to eq(
      "duration_minutes" => 45,
      "mood" => "great",
      "share" => true
    )
  end

  it "validates required schema fields after normalization" do
    schema = Igniter::SchemaRendering::Schema.load(schema_payload)
    normalized = { "duration_minutes" => nil, "mood" => "great", "share" => false }

    errors = Igniter::SchemaRendering::SubmissionValidator.new(schema).validate(
      normalized,
      action_id: "submit_checkin"
    )

    expect(errors).to eq("duration_minutes" => "is required")
  end

  it "re-renders schema values and field errors in the shared UI shell" do
    html = Igniter::SchemaRendering::Renderer.render(
      schema: schema_payload,
      values: { "duration_minutes" => "", "mood" => "great" },
      errors: { "duration_minutes" => "is required" },
      notice: "Please review the highlighted fields."
    )

    expect(html).to include("Please review the highlighted fields.")
    expect(html).to include("is required")
    expect(html).to include('class="w-full rounded-2xl border border-white/10 bg-[#160f0d]')
    expect(html).to include("<fieldset")
    expect(html).to include("Double-check duration before submitting.")
    expect(html).to include('option value="great" selected')
  end

  it "rejects invalid schema nodes" do
    broken_payload = Marshal.load(Marshal.dump(schema_payload))
    broken_payload[:layout][:children][3][:children][0][:children][0].delete(:label)

    expect do
      Igniter::SchemaRendering::Schema.load(broken_payload)
    end.to raise_error(Igniter::SchemaRendering::Schema::Error, /label is required/)
  end

  it "rejects invalid patches" do
    store = Igniter::SchemaRendering::Store.new
    store.put(schema_payload)

    expect do
      store.patch(
        "training-checkin",
        patch: {
          layout: {
            children: [
              {
                type: "form",
                action: "submit_checkin",
                children: [
                  {
                    type: "fieldset",
                    children: [{ type: "input", name: "x" }]
                  }
                ]
              }
            ]
          }
        }
      )
    end.to raise_error(Igniter::SchemaRendering::Schema::Error, /label is required/)
  end
end
