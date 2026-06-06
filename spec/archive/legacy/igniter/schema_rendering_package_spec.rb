# frozen_string_literal: true

require "spec_helper"
require_relative "../../packages/igniter-schema-rendering/lib/igniter-schema-rendering"

RSpec.describe "igniter-schema-rendering local gem facade" do
  it "re-exports schema-driven page and renderer lanes" do
    expect(Igniter::SchemaRendering::Page.superclass).to eq(Object)
    expect(Igniter::SchemaRendering::Renderer.superclass).to eq(Igniter::Frontend::Component)
    expect(Igniter::SchemaRendering::Store::DEFAULT_COLLECTION).to eq("igniter_view_schemas")
    expect(Igniter::SchemaRendering::Patcher).to respond_to(:apply)
    expect(Igniter::SchemaRendering::SubmissionNormalizer).to respond_to(:new)
    expect(Igniter::SchemaRendering::SubmissionProcessor).to respond_to(:call)
    expect(Igniter::SchemaRendering::SubmissionValidator).to respond_to(:new)
  end
end
