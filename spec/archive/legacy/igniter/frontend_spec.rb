# frozen_string_literal: true

require "spec_helper"
require "igniter-frontend"

RSpec.describe Igniter::Frontend do
  class TestMetricCard < Igniter::Frontend::Component
    def initialize(label:, value:)
      @label = label
      @value = value
    end

    def call(view)
      view.tag(:div, class: "metric") do |card|
        card.tag(:strong, @label)
        card.tag(:span, @value, class: "value")
      end
    end
  end

  class TestPage < Igniter::Frontend::Page
    def call(view)
      render_document(view, title: "View Test") do |body|
        body.tag(:main) do |main|
          main.component(TestMetricCard, label: "Notes", value: 4)
          main.form(action: "/checkins") do |form|
            form.label("mood", "Mood")
            form.select("mood", options: [["Great", "great"], ["Okay", "okay"]], selected: "okay", id: "mood")
            form.textarea("notes", value: "Felt good today", rows: 3)
            form.checkbox("public", checked: true)
            form.submit("Save")
          end
        end
      end
    end
  end

  describe ".render" do
    it "renders nested HTML and escapes text and attributes" do
      html = described_class.render do |view|
        view.doctype
        view.tag(:div, class: ["card", "accent"], data: { chat_id: 123 }, hidden: true) do |div|
          div.tag(:strong, "<hello>")
          div.tag(:br)
          div.text("A & B")
        end
      end

      expect(html).to include("<!DOCTYPE html>")
      expect(html).to include('<div class="card accent" data-chat-id="123" hidden>')
      expect(html).to include("<strong>&lt;hello&gt;</strong>")
      expect(html).to include("<br>")
      expect(html).to include("A &amp; B")
    end
  end

  it "renders components and forms through page abstractions" do
    html = TestPage.render

    expect(html).to include("<!DOCTYPE html>")
    expect(html).to include("<title>View Test</title>")
    expect(html).to include('<div class="metric"><strong>Notes</strong><span class="value">4</span></div>')
    expect(html).to include('<form action="/checkins" method="post">')
    expect(html).to include('<label for="mood">Mood</label>')
    expect(html).to include('<option value="okay" selected>Okay</option>')
    expect(html).to include("<textarea")
    expect(html).to include('name="notes"')
    expect(html).to include('rows="3"')
    expect(html).to include(">Felt good today</textarea>")
    expect(html).to include('<input type="checkbox" name="public" value="1" checked>')
    expect(html).to include('<button type="submit">Save</button>')
  end

  describe Igniter::Frontend::Response do
    it "builds a standard HTML response" do
      response = described_class.html("<h1>Hello</h1>", headers: { "X-Test" => "1" })

      expect(response).to eq(
        status: 200,
        body: "<h1>Hello</h1>",
        headers: {
          "Content-Type" => "text/html; charset=utf-8",
          "X-Test" => "1"
        }
      )
    end
  end
end

RSpec.describe Igniter::Frontend::Arbre do
  it "treats Arbre as the standard frontend authoring dependency" do
    expect([true, false]).to include(described_class.available?)
  end

  it "either exposes Arbre classes or raises a bundled-dependency installation error" do
    if described_class.available?
      expect(described_class.component_class.name).to eq("Arbre::Component")
      expect(described_class.context_class.name).to eq("Arbre::Context")
    else
      expect do
        described_class.component_class
      end.to raise_error(described_class::MissingDependencyError, /ships with a required `arbre` dependency/)
    end
  end
end

RSpec.describe Igniter::Frontend::Tailwind do
  it "renders a Tailwind-friendly page shell with an optional config script" do
    html = described_class.render_page(
      title: "Ops Dashboard",
      theme: :ops,
      tailwind_config: {
        theme: {
          extend: {
            colors: {
              accent: "#C2410C"
            }
          }
        }
      }
    ) do |main|
      main.tag(:section, class: "rounded-3xl border border-white/10 bg-white/5 p-8 shadow-2xl shadow-black/30") do |section|
        section.tag(:p, "Nodes healthy", class: "text-sm uppercase tracking-[0.3em] text-orange-300")
        section.tag(:h1, "Cluster Control", class: "mt-4 text-4xl font-semibold text-white")
      end
    end

    expect(html).to include("<!DOCTYPE html>")
    expect(html).to include("<title>Ops Dashboard</title>")
    expect(html).to include(Igniter::Frontend::Tailwind::PLAY_CDN_URL)
    expect(html).to include("bg-stone-950")
    expect(html).to include("tailwind.config = ")
    expect(html).to include('"lab":{"accent":"#D97706","canvas":"#0c0a09","panel":"#1c1917","line":"#292524"}')
    expect(html).to include('"accent":"#C2410C"')
    expect(html).to include("rounded-3xl")
    expect(html).to include("Cluster Control")
  end

  it "applies a built-in theme while allowing local layout overrides" do
    html = described_class.render_message_page(
      title: "Companion Notice",
      eyebrow: "Companion",
      message: "Shared theme shell",
      back_label: "Back",
      back_path: "/dashboard",
      theme: :companion,
      main_class: "mx-auto flex min-h-screen w-full max-w-4xl flex-col gap-6 px-4 py-6"
    )

    expect(html).to include("bg-[#160f0d]")
    expect(html).to include("max-w-4xl")
    expect(html).to include('"companion":{"accent":"#c26b3d","panel":"#2a1914"}')
    expect(html).to include("Shared theme shell")
  end

  it "can inject additional head content" do
    html = described_class.render_page(
      title: "Ops Dashboard",
      head_content: lambda { |head|
        head.tag(:script, type: "text/javascript") { |script| script.raw("window.tailwindReady = true;") }
      }
    ) do |main|
      main.tag(:p, "Hello")
    end

    expect(html).to include("window.tailwindReady = true;")
    expect(html).to include("<p>Hello</p>")
  end

  it "can render a shared realtime head with projections and a hook" do
    html = described_class.render_page(
      title: "Live Ops",
      head_content: lambda { |head|
        described_class::Realtime.render_head(
          head,
          config: {
            overview_path: "/api/overview",
            stream_path: "/api/overview/stream",
            poll_interval_seconds: 5
          },
          projections: {
            overview: {
              metrics: { "devices-online" => "counts.devices_online" },
              charts: { "device-status" => "charts.device_status" }
            },
            activity: {
              cases: {
                "device_heartbeat" => {
                  metric_deltas: { "heartbeats" => 1 },
                  chart_deltas: { "activity-mix.heartbeats" => 1 }
                }
              }
            }
          },
          hook_name: "dashboardRealtimeHook",
          include_mermaid: true,
          extra_script: "window.dashboardRealtimeHook = function() {};"
        )
      }
    ) do |main|
      main.tag(:p, "Hello")
    end

    expect(html).to include(Igniter::Frontend::Tailwind::MERMAID_CDN_URL)
    expect(html).to include("\"stream_path\":\"/api/overview/stream\"")
    expect(html).to include("\"devices-online\":\"counts.devices_online\"")
    expect(html).to include("\"activity-mix.heartbeats\":1")
    expect(html).to include("new window.EventSource")
    expect(html).to include("dashboardRealtimeHook")
    expect(html).to include("window.dashboardRealtimeHook = function() {};")
  end

  it "can compose reusable realtime projection adapters into a hook" do
    script = described_class::Realtime::Adapters.compose_hook(
      name: "opsRealtimeHook",
      adapters: [
        described_class::Realtime::Adapters.prompt_buttons(textarea_id: "chat-message"),
        described_class::Realtime::Adapters.device_presence(
          device_selector: "[data-device-id=\"__ID__\"]",
          bootstrap_selector: "[data-device-id]",
          status_badge_selector_template: "[data-device-status-badge=\"__ID__\"]",
          last_seen_selector_template: "[data-device-last-seen=\"__ID__\"]",
          telemetry_selector_template: "[data-device-telemetry=\"__ID__\"]",
          topology_status_selector: "[data-topology-overall-status='true']",
          topology_counts_selector: "[data-topology-device-count]",
          chart_id: "device-status",
          online_metric_id: "devices-online",
          status_badge_base_class: Igniter::Frontend::Tailwind::UI::StatusBadge::DEFAULT_BASE_CLASS
        ),
        described_class::Realtime::Adapters.chat_transcript(
          selector: "[data-chat-list='true']",
          item_class: "chat-item",
          muted_class: "muted",
          body_class: "body",
          status_badge_base_class: Igniter::Frontend::Tailwind::UI::StatusBadge::DEFAULT_BASE_CLASS,
          limit: 10
        ),
        described_class::Realtime::Adapters.activity_timeline(
          selector: "[data-activity-timeline='true']",
          item_class: "timeline-item",
          title_class: "title",
          muted_class: "muted",
          link_class: "link",
          action_class: "action",
          limit: 8,
          source_urls: {
            "note" => "/api/notes",
            "camera_event" => "/api/camera_events",
            "device_heartbeat" => "/api/devices"
          }
        )
      ]
    )

    expect(script).to include("window[\"opsRealtimeHook\"]")
    expect(script).to include("document.getElementById(\"chat-message\")")
    expect(script).to include("devicePresenceState")
    expect(script).to include("[data-device-id]")
    expect(script).to include("payload.type !== \"chat_turn\"")
    expect(script).to include("[data-activity-timeline='true']")
    expect(script).to include("\"camera_event\":\"/api/camera_events\"")
  end

  it "can build a reusable operator-surface preset and render it into the page head" do
    preset = described_class::Realtime::Presets.operator_surface(
      hook_name: "opsPresetHook",
      projections: {
        overview: {
          metrics: { "devices-online" => "counts.devices_online" }
        }
      },
      adapters: [
        described_class::Realtime::Adapters.prompt_buttons(textarea_id: "chat-message")
      ],
      include_mermaid: true
    )

    html = described_class.render_page(
      title: "Preset Page",
      head_content: lambda { |head|
        preset.render_head(
          head,
          config: {
            overview_path: "/api/overview",
            stream_path: "/api/overview/stream",
            poll_interval_seconds: 5
          }
        )
      }
    ) do |main|
      main.tag(:p, "Preset body")
    end

    expect(preset.hook_name).to eq("opsPresetHook")
    expect(preset.projections.dig(:overview, :metrics, "devices-online")).to eq("counts.devices_online")
    expect(preset.include_mermaid).to eq(true)
    expect(preset.extra_script).to include("window[\"opsPresetHook\"]")
    expect(html).to include(Igniter::Frontend::Tailwind::MERMAID_CDN_URL)
    expect(html).to include("window[\"opsPresetHook\"]")
    expect(html).to include("Preset body")
  end

  it "exposes a home-ops preset for dashboard-style operator surfaces" do
    theme = described_class::UI::Theme.fetch(:ops)
    preset = described_class::Realtime::Presets.home_ops(theme: theme)

    expect(preset.hook_name).to eq("homeLabRealtimeProjector")
    expect(preset.projections.dig(:overview, :charts, "device-status")).to eq("charts.device_status")
    expect(preset.projections.dig(:activity, :cases, "chat_turn", :feed)).to eq(false)
    expect(preset.extra_script).to include("[data-chat-list='true']")
    expect(preset.extra_script).to include("[data-device-id]")
    expect(preset.extra_script).to include("http://127.0.0.1:4570/v1/camera_events")
  end

  it "renders a shared message page shell" do
    html = described_class.render_message_page(
      title: "Missing View",
      eyebrow: "Schema Page",
      message: "No schema stored for training-checkin.",
      detail: "view_id=training-checkin",
      back_label: "Back to dashboard",
      back_path: "/dashboard"
    )

    expect(html).to include("<!DOCTYPE html>")
    expect(html).to include("Missing View")
    expect(html).to include("Schema Page")
    expect(html).to include("No schema stored for training-checkin.")
    expect(html).to include("view_id=training-checkin")
    expect(html).to include('href="/dashboard"')
  end

  it "can render without injecting the Tailwind Play CDN" do
    html = described_class.render_page(title: "Local Page", include_play_cdn: false) do |main|
      main.tag(:p, "Hello")
    end

    expect(html).not_to include(Igniter::Frontend::Tailwind::PLAY_CDN_URL)
    expect(html).to include("<p>Hello</p>")
  end
end

RSpec.describe Igniter::Frontend::Tailwind::UI do
  it "renders reusable metric cards, panels, and status badges" do
    html = Igniter::Frontend.render do |view|
      view.component(
        described_class::MetricCard,
        label: "Alerts",
        value: 3,
        hint: "pending",
        wrapper_attributes: { data: { metric_id: "alerts" } },
        value_attributes: { data: { metric_value: "alerts" } }
      )
      view.component(described_class::Panel.new(title: "Control", subtitle: "Main surface") do |panel|
        panel.component(described_class::StatusBadge, label: "ready", html_attributes: { data: { status_id: "control" } })
      end)
    end

    expect(html).to include("Alerts")
    expect(html).to include("pending")
    expect(html).to include('data-metric-id="alerts"')
    expect(html).to include('data-metric-value="alerts"')
    expect(html).to include("Control")
    expect(html).to include("Main surface")
    expect(html).to include("status-badge")
    expect(html).to include("ready")
    expect(html).to include('data-status-id="control"')
  end

  it "renders reusable message pages" do
    html = Igniter::Frontend.render do |view|
      view.component(
        described_class::MessagePage.new(
          title: "Submission Error",
          eyebrow: "Schema Submission",
          message: "missing form action",
          detail: "view_id=training-checkin",
          back_label: "Back to view",
          back_path: "/views/training-checkin"
        )
      )
    end

    expect(html).to include("Submission Error")
    expect(html).to include("Schema Submission")
    expect(html).to include("missing form action")
    expect(html).to include("view_id=training-checkin")
    expect(html).to include('href="/views/training-checkin"')
  end

  it "renders reusable banners, fields, and inline actions" do
    html = Igniter::Frontend.render do |view|
      view.component(described_class::Banner.new(message: "Please review the highlighted fields.", tone: :warning))
      view.component(described_class::Field.new(id: "task", label: "Task", error: "is required") do |field|
        Igniter::Frontend::FormBuilder.new(field).input("task", id: "task", class: "field-input")
      end)
      view.component(described_class::InlineActions.new do |actions|
        actions.tag(:a, "Back", href: "/")
        actions.tag(:button, "Retry", type: "submit")
      end)
    end

    expect(html).to include("Please review the highlighted fields.")
    expect(html).to include("Task")
    expect(html).to include("is required")
    expect(html).to include('class="field-input"')
    expect(html).to include("Back")
    expect(html).to include("Retry")
  end

  it "renders semantic submission notices, field groups, and choice fields" do
    html = Igniter::Frontend.render do |view|
      view.component(described_class::SubmissionNotice.new(message: "Please review the highlighted fields."))
      view.component(described_class::FieldGroup.new(id: "task", label: "Task", error: "is required") do |field|
        Igniter::Frontend::FormBuilder.new(field).input("task", id: "task", class: "field-input")
      end)
      view.component(
        described_class::ChoiceField.new(
          kind: :select,
          name: "mood",
          id: "mood",
          label: "Mood",
          selected: "good",
          options: [["Great", "great"], ["Good", "good"]],
          input_class: "field-select"
        )
      )
      view.component(
        described_class::ChoiceField.new(
          kind: :checkbox,
          name: "share",
          id: "share",
          label: "Share with coach",
          checked: true,
          checkbox_label_class: "checkbox-shell",
          checkbox_class: "checkbox-input"
        )
      )
    end

    expect(html).to include("Please review the highlighted fields.")
    expect(html).to include("Task")
    expect(html).to include("is required")
    expect(html).to include('class="field-input"')
    expect(html).to include('class="field-select"')
    expect(html).to include('option value="good" selected')
    expect(html).to include("Share with coach")
    expect(html).to include('class="checkbox-input"')
  end

  it "renders semantic schema hero and layout blocks" do
    html = Igniter::Frontend.render do |view|
      view.component(
        described_class::SchemaHero.new(
          title: "Daily Training Check-in",
          description: "Schema-driven page.",
          wrapper_class: "schema-hero",
          eyebrow_class: "schema-eyebrow",
          title_class: "schema-title",
          body_class: "schema-body"
        )
      )
      view.component(described_class::SchemaStack.new(class_name: "schema-stack") { |stack| stack.tag(:p, "Stack body") })
      view.component(described_class::SchemaGrid.new(class_name: "schema-grid") { |grid| grid.tag(:p, "Grid body") })
      view.component(described_class::SchemaIntro.new(text: "Intro body", class_name: "schema-intro", muted_class: "schema-intro-muted"))
      view.component(
        described_class::SchemaForm.new(
          action: "/submit",
          hidden_action: "save",
          class_name: "schema-form",
          fieldset: {
            legend: "Training",
            description: "Daily inputs",
            class_name: "schema-fieldset",
            legend_class: "schema-legend",
            description_class: "schema-description"
          }
        ) do |_form, fieldset|
          fieldset.tag(:p, "Fieldset body")
        end
      )
      view.component(described_class::SchemaSection.new(class_name: "schema-section") { |section| section.tag(:p, "Section body") })
      view.component(described_class::SchemaCard.new(class_name: "schema-card") { |card| card.tag(:p, "Card body") })
    end

    expect(html).to include("Daily Training Check-in")
    expect(html).to include("Schema-driven page.")
    expect(html).to include('class="schema-stack"')
    expect(html).to include('class="schema-grid"')
    expect(html).to include('class="schema-intro"')
    expect(html).to include('class="schema-form"')
    expect(html).to include("<fieldset")
    expect(html).to include("Training")
    expect(html).to include("Daily inputs")
    expect(html).to include('class="schema-section"')
    expect(html).to include('class="schema-card"')
  end

  it "renders reusable action bars, form sections, and key-value lists" do
    html = Igniter::Frontend.render do |view|
      view.component(described_class::ActionBar.new(tag: :nav) do |bar|
        bar.tag(:a, "Overview", href: "/overview")
        bar.tag(:a, "Devices", href: "/devices")
      end)

      view.component(described_class::FormSection.new(title: "Reminder", subtitle: "Fast create", action: "/reminders") do |form|
        form.label("task", "Task")
        form.input("task", id: "task")
        form.submit("Create")
      end)

      view.component(described_class::KeyValueList.new(rows: [["role", "dashboard"], ["port", 4569]]))
    end

    expect(html).to include("<nav")
    expect(html).to include("Overview")
    expect(html).to include("Devices")
    expect(html).to include("Reminder")
    expect(html).to include("Fast create")
    expect(html).to include('action="/reminders"')
    expect(html).to include("<dt")
    expect(html).to include("dashboard")
    expect(html).to include("4569")
  end

  it "renders semantic property, resource, endpoint, and timeline components" do
    theme = described_class::Theme.fetch(:ops)

    html = Igniter::Frontend.render do |view|
      view.component(
        described_class::PropertyCard.new(
          title: "main-app",
          href: "/apps/main",
          body: "role=dashboard",
          meta: "replicas=1",
          code: "apps/main",
          action_label: "Open",
          action_href: "/apps/main",
          wrapper_class: theme.list_item_class,
          title_class: theme.item_title_class,
          body_class: theme.body_text_class,
          meta_class: theme.muted_text_class,
          code_class: theme.code_class,
          link_class: "transition hover:text-amber-200",
          action_class: "mt-3 inline-flex text-sm"
        )
      )
      view.component(
        theme.resource_list(
          items: [{ title: "Store", code: "/tmp/store.db", meta: "bytes=12" }],
          compact: true
        )
      )
      view.component(
        theme.endpoint_list(
          items: [{ title: "Health", href: "/health", meta: "role=main" }],
          compact: true,
          link_class: "text-amber-200"
        )
      )
      view.component(
        theme.timeline_list(
          items: [{
            title: "note · Saved",
            href: "/?focus=1",
            body: "Captured observation",
            meta: "2m ago",
            action_label: "open source",
            action_href: "/api/notes/1"
          }],
          title_link_class: "transition hover:text-amber-200",
          action_link_class: "mt-3 inline-flex text-sm"
        )
      )
      view.component(
        theme.payload_diff(
          raw_payload: { "_action" => "save_review", "duration_minutes" => "45", "share" => "1" },
          normalized_payload: { "duration_minutes" => 45, "share" => true }
        )
      )
      view.component(
        theme.bar_chart(
          chart_id: "device-status",
          items: [
            { key: "online", label: "Online", value: 2 },
            { key: "offline", label: "Offline", value: 1 }
          ]
        )
      )
      view.component(
        theme.mermaid_diagram(
          diagram: "flowchart LR\n  edge --> dashboard",
          title: "Topology Mermaid"
        )
      )
      view.component(
        theme.live_badge(
          label: "Live mode",
          value: "2026-04-16T13:20:00Z",
          interval_seconds: 5
        )
      )
    end

    expect(html).to include("main-app")
    expect(html).to include('href="/apps/main"')
    expect(html).to include("/tmp/store.db")
    expect(html).to include("Health")
    expect(html).to include('href="/health"')
    expect(html).to include("note · Saved")
    expect(html).to include("open source")
    expect(html).to include("duration_minutes")
    expect(html).to include("Type changed during normalization.")
    expect(html).to include("Field value changed during normalization.")
    expect(html).to include('data-chart-id="device-status"')
    expect(html).to include('data-chart-fill="online"')
    expect(html).to include("Topology Mermaid")
    expect(html).to include("flowchart LR")
    expect(html).to include('class="mermaid')
    expect(html).to include("Live mode")
    expect(html).to include("poll 5s")
  end
end

RSpec.describe Igniter::Frontend::Tailwind::UI::Theme do
  it "builds themed panels, form sections, and message page options" do
    theme = described_class.fetch(:companion)

    html = Igniter::Frontend.render do |view|
      view.component(theme.panel(title: "Control", subtitle: "Shared surface") { |panel| panel.tag(:p, "Hello") })
      view.component(
        theme.form_section(title: "Reminder", subtitle: "Fast create", action: "/reminders") do |form|
          form.label("task", "Task")
          form.input("task", id: "task")
        end
      )
      view.component(
        Igniter::Frontend::Tailwind::UI::MessagePage.new(
          title: "Missing View",
          eyebrow: "Companion",
          message: "No page registered.",
          back_label: "Back",
          back_path: "/dashboard",
          **theme.message_page_options
        )
      )
    end

    expect(html).to include("bg-[#2a1914]/90")
    expect(html).to include("Shared surface")
    expect(html).to include('action="/reminders"')
    expect(html).to include("Missing View")
    expect(html).to include("No page registered.")
  end

  it "exposes shared hero and surface presets" do
    theme = described_class.fetch(:ops)
    hero = theme.hero(:dashboard)

    expect(hero.fetch(:wrapper_class)).to include("shadow-glow")
    expect(hero.fetch(:eyebrow_class)).to include("text-amber-200/75")
    expect(theme.panel(title: "Topology")).to be_a(Igniter::Frontend::Tailwind::UI::Panel)
  end

  it "exposes shared field, checkbox, code, and empty-state helpers" do
    companion = described_class.fetch(:companion)
    schema = described_class.fetch(:schema)
    ops = described_class.fetch(:ops)

    expect(companion.input_class).to include("bg-[#160f0d]")
    expect(companion.checkbox_label_class).to include("items-center")
    expect(companion.checkbox_class).to include("text-orange-300")
    expect(schema.field_label_class).to include("uppercase")
    expect(ops.code_class).to include("text-amber-100")
    expect(ops.empty_state_class(extra: "empty-state")).to include("empty-state")
    expect(ops.muted_text_class(extra: "muted")).to include("muted")
  end

  it "exposes shared list, card, and heading helpers" do
    companion = described_class.fetch(:companion)
    ops = described_class.fetch(:ops)

    expect(companion.list_class).to include("space-y-4")
    expect(companion.list_item_class).to include("rounded-3xl")
    expect(companion.item_title_class).to include("font-semibold")
    expect(companion.body_text_class(extra: "mt-2")).to include("mt-2")
    expect(ops.compact_list_class).to include("compact")
    expect(ops.compact_card_class).to include("rounded-2xl")
    expect(ops.compact_item_class).to include("text-sm")
    expect(ops.section_heading_class).to include("tracking-[0.22em]")
  end

  it "builds semantic list components from the shared theme" do
    theme = described_class.fetch(:ops)

    expect(theme.resource_list(items: [])).to be_a(Igniter::Frontend::Tailwind::UI::ResourceList)
    expect(theme.endpoint_list(items: [], link_class: "text-amber-200")).to be_a(Igniter::Frontend::Tailwind::UI::EndpointList)
    expect(theme.timeline_list(items: [], title_link_class: "hover:text-amber-200", action_link_class: "text-sm")).to be_a(Igniter::Frontend::Tailwind::UI::TimelineList)
    expect(theme.payload_diff(raw_payload: {}, normalized_payload: {})).to be_a(Igniter::Frontend::Tailwind::UI::PayloadDiff)
    expect(theme.bar_chart(items: [], chart_id: "ops")).to be_a(Igniter::Frontend::Tailwind::UI::BarChart)
    expect(theme.mermaid_diagram(diagram: "flowchart LR")).to be_a(Igniter::Frontend::Tailwind::UI::MermaidDiagram)
    expect(theme.live_badge(label: "Live", value: "now", interval_seconds: 5)).to be_a(Igniter::Frontend::Tailwind::UI::LiveBadge)
  end

  it "builds semantic schema layout components from the shared theme" do
    theme = described_class.fetch(:schema)

    expect(theme.schema_hero(title: "Schema")).to be_a(Igniter::Frontend::Tailwind::UI::SchemaHero)
    expect(theme.schema_intro(text: "Intro")).to be_a(Igniter::Frontend::Tailwind::UI::SchemaIntro)
    expect(theme.schema_form(action: "/submit")).to be_a(Igniter::Frontend::Tailwind::UI::SchemaForm)
    expect(theme.schema_stack {}).to be_a(Igniter::Frontend::Tailwind::UI::SchemaStack)
    expect(theme.schema_grid {}).to be_a(Igniter::Frontend::Tailwind::UI::SchemaGrid)
    expect(theme.schema_fieldset {}).to be_a(Igniter::Frontend::Tailwind::UI::SchemaFieldset)
    expect(theme.schema_section {}).to be_a(Igniter::Frontend::Tailwind::UI::SchemaSection)
    expect(theme.schema_card {}).to be_a(Igniter::Frontend::Tailwind::UI::SchemaCard)
  end
end

RSpec.describe Igniter::Frontend::Tailwind::Surfaces do
  it "builds an ops-dashboard surface preset with theme, realtime, and hook helpers" do
    preset = described_class.ops_dashboard

    metric = preset.metric_card(id: "devices-online", label: "Devices Online", value: 2, hint: "heartbeat within 5 min")

    html = Igniter::Frontend.render do |view|
      view.component(metric)
      view.tag(:ul, **preset.notes_list_attributes) { |list| list.tag(:li, "note") }
      view.tag(:ul, **preset.chat_list_attributes) { |list| list.tag(:li, "chat") }
      view.tag(:ul, **preset.camera_events_list_attributes) { |list| list.tag(:li, "camera") }
      view.tag(:ul, **preset.activity_timeline_attributes) { |list| list.tag(:li, "timeline") }
      view.tag(:div, "device", **preset.device_item_attributes(id: "front_door_cam", status: "offline"))
      view.component(Igniter::Frontend::Tailwind::UI::StatusBadge.new(label: "offline", html_attributes: preset.device_status_badge_attributes("front_door_cam")))
      view.component(Igniter::Frontend::Tailwind::UI::StatusBadge.new(label: "degraded", html_attributes: preset.topology_overall_status_attributes))
      view.tag(:span, "offline=1", **preset.topology_device_count_attributes("offline"))
    end

    expect(preset.name).to eq(:ops_dashboard)
    expect(preset.theme_name).to eq(:ops)
    expect(preset.realtime_preset).not_to be_nil
    expect(preset.components).to include(
      :metric_card,
      :bar_chart,
      :live_badge,
      :ops_hero_actions,
      :operations_pulse,
      :realtime_feed,
      :chat_prompt_bar,
      :activity_filter_bar,
      :timeline_focus_actions,
      :device_inventory,
      :notes_list,
      :chat_transcript,
      :camera_events_list,
      :activity_timeline,
      :devices_panel,
      :notes_panel,
      :chat_panel,
      :camera_events_panel,
      :timeline_panel,
      :timeline_focus_panel,
      :health_readiness_panel,
      :topology_health_panel,
      :network_topology_panel,
      :app_services_panel,
      :resources_panel,
      :debug_surfaces_panel,
      :next_ideas_panel,
      :topology_flow_panel,
      :execution_flow_panel
    )
    expect(preset.hooks.fetch(:realtime_feed)).to eq("realtime_feed")
    expect(html).to include('data-metric-value="devices-online"')
    expect(html).to include('data-notes-list="true"')
    expect(html).to include('data-chat-list="true"')
    expect(html).to include('data-camera-events-list="true"')
    expect(html).to include('data-activity-timeline="true"')
    expect(html).to include('data-device-id="front_door_cam"')
    expect(html).to include('data-device-status-badge="front_door_cam"')
    expect(html).to include('data-topology-overall-status="true"')
    expect(html).to include('data-topology-device-count="offline"')
  end

  it "renders semantic ops dashboard content blocks from the surface preset" do
    preset = described_class.ops_dashboard

    html = Igniter::Frontend.render do |view|
      preset.ops_hero_actions(
        view,
        endpoints: [
          { "label" => "Main health", "path" => "/health" }
        ]
      )
      preset.operations_pulse(
        view,
        generated_at: "2026-04-16T12:00:00Z",
        poll_interval_seconds: 5,
        charts: {
          device_status: [{ "label" => "Online", "value" => 1 }, { "label" => "Offline", "value" => 2 }],
          activity_mix: [{ "label" => "Notes", "value" => 3 }],
          app_roles: [{ "label" => "Admin", "value" => 1 }]
        }
      )
      preset.realtime_feed(
        view,
        stream_path: "/api/overview/stream",
        events: [{ "title" => "Heartbeat", "detail" => "front_door_cam online" }]
      )
      preset.chat_prompt_bar(view, prompts: ["Which devices are online right now?"])
      preset.activity_filter_bar(
        view,
        items: [
          { label: "All activity", href: "/", active: true },
          { label: "Only notes", href: "/?timeline=note", active: false }
        ]
      )
      preset.timeline_focus_actions(
        view,
        source_url: "/api/notes",
        clear_path: "/?timeline=note"
      )
      preset.device_inventory(
        view,
        devices: [
          {
            id: :front_door_cam,
            title: "front_door_cam",
            href: "/devices/front_door_cam",
            subtitle: "esp32_cam via http",
            code: "routes_to=edge",
            status: "online",
            last_seen: "last_seen=just now",
            telemetry: "battery=88 signal=-60 ip=192.168.0.10"
          }
        ],
        empty_message: "No devices declared yet."
      )
      preset.notes_list(
        view,
        notes: [{ id: "note-1", title: "Top off the UPS rack", meta: "source=dashboard · created=2m ago" }],
        empty_message: "No notes saved yet."
      )
      preset.chat_transcript(
        view,
        messages: [{ id: "chat-1", role: "assistant", meta: "operator_chat · just now", body: "Devices online: 1." }],
        empty_message: "No chat turns yet."
      )
      preset.camera_events_list(
        view,
        events: [{ id: "cam-1", title: "front-door-cam", meta: "motion=true · source=esp32-cam", body: "Courier at the front door" }],
        empty_message: "No camera events yet."
      )
      preset.activity_timeline(
        view,
        items: [{ id: "evt-1", type: "note", title: "note · UPS check", href: "/?timeline=note&focus=evt-1", detail: "Top off the UPS rack", age: "2m ago", source_url: "/api/notes" }],
        empty_message: "No activity yet."
      )
      view.component(
        preset.devices_panel(
          devices: [
            {
              id: :front_door_cam,
              title: "front_door_cam",
              href: "/devices/front_door_cam",
              subtitle: "esp32_cam via http",
              code: "routes_to=edge",
              status: "online",
              last_seen: "last_seen=just now",
              telemetry: "battery=88 signal=-60 ip=192.168.0.10"
            }
          ],
          empty_message: "No devices declared yet."
        )
      )
      view.component(
        preset.notes_panel(
          notes: [{ id: "note-1", title: "Top off the UPS rack", meta: "source=dashboard · created=2m ago" }],
          empty_message: "No notes saved yet.",
          error_message: "Note save failed"
        ) do |panel|
          panel.form(action: "/notes", method: "post") { |form| form.submit("Save Note") }
        end
      )
      view.component(
        preset.chat_panel(
          messages: [{
            id: "chat-1",
            role: "assistant",
            meta: "operator_chat · just now",
            body: "Proposed action: save note.",
            action: {
              title: "Create Note",
              status: "confirmation required",
              preview: "refill filament stock",
              meta: "queued for confirmation just now",
              details: [
                { label: "Prompt", value: "Remember: refill filament stock" },
                { label: "Updated", value: "just now" }
              ],
              payload: {
                action_key: "chat-action-create-note-remember-refill-filament-stock",
                type: "create_note",
                status: "confirmation_required",
                prompt: "Remember: refill filament stock"
              },
              confirm: {
                path: "/chat",
                hidden: { "message" => "Remember: refill filament stock", "confirm" => "1" },
                label: "Confirm pending action",
                class_name: "confirm-action"
              },
              dismiss: {
                path: "/chat",
                hidden: { "message" => "Remember: refill filament stock", "dismiss" => "1" },
                label: "Dismiss",
                class_name: "dismiss-action"
              }
            }
          }],
          prompts: ["Which devices are online right now?"],
          empty_message: "No chat turns yet.",
          error_message: "Chat send failed",
          action_history: [{
            action_key: "chat-action-create-note-remember-refill-filament-stock",
            title: "Create Note",
            status: "completed",
            preview: "refill filament stock",
            meta: "completed just now",
            details: [
              { label: "Note ID", value: "note-123" },
              { label: "Updated", value: "just now" }
            ],
            payload: {
              action_key: "chat-action-create-note-remember-refill-filament-stock",
              type: "create_note",
              status: "completed",
              note_id: "note-123",
              note_text: "refill filament stock"
            }
          }]
        ) do |panel|
          panel.form(action: "/chat", method: "post") { |form| form.submit("Send to Igniter") }
        end
      )
      view.component(
        preset.camera_events_panel(
          events: [{ id: "cam-1", title: "front-door-cam", meta: "motion=true · source=esp32-cam", body: "Courier at the front door" }],
          empty_message: "No camera events yet."
        )
      )
      view.component(
        preset.timeline_panel(
          filter_items: [
            { label: "All activity", href: "/", active: true },
            { label: "Only notes", href: "/?timeline=note", active: false }
          ],
          items: [{ id: "evt-1", type: "note", title: "note · UPS check", href: "/?timeline=note&focus=evt-1", detail: "Top off the UPS rack", age: "2m ago", source_url: "/api/notes" }],
          empty_message: "No activity yet."
        )
      )
      view.component(
        preset.timeline_focus_panel(
          entry: {
            type: "note",
            title: "UPS check",
            detail: "Top off the UPS rack",
            seen: "2m ago",
            source_url: "/api/notes"
          },
          clear_path: "/?timeline=note"
        )
      )
      view.component(
        preset.health_readiness_panel(
          surfaces: [{ title: "main", status: "ready", meta: "role=core · readiness=ok", url: "/health" }],
          empty_message: "No health surfaces declared yet."
        )
      )
      view.component(
        preset.topology_health_panel(
          health: {
            overall_status: "degraded",
            readiness_summary: "ready_app_surfaces=2/3",
            device_status_counts: [{ status: "online", label: "online=1" }, { status: "offline", label: "offline=1" }],
            alerts: ["front_door_cam missed heartbeat"]
          }
        )
      )
      view.component(
        preset.network_topology_panel(
          topology_notes: ["edge depends on main"],
          public_endpoints: [{ title: "dashboard", href: "http://127.0.0.1:4571", meta: "role=admin port=4571" }],
          dependency_edges: ["edge -> main"]
        )
      )
      view.component(
        preset.app_services_panel(
          services: [{
            title: "edge",
            href: "/apps/edge",
            meta: "role=edge · port=4570 · replicas=1 · public=true",
            class_name: "HomeLab::EdgeApp",
            command: "bundle exec ruby stack.rb edge",
            path: "path=apps/edge",
            depends_on: "depends_on=main"
          }],
          empty_message: "No app services declared yet."
        )
      )
      view.component(
        preset.resources_panel(
          stores: [{ title: "Shared notes store", code: "var/home-lab/notes.json" }],
          var_files: [{ title: "operator.json", meta: "bytes=128 · updated=2026-04-16T12:00:00Z", code: "var/home-lab/operator.json" }],
          total_var_bytes: 128
        )
      )
      view.component(
        preset.debug_surfaces_panel(
          api_items: [{ title: "Main health", href: "/health" }],
          files: ["playgrounds/home-lab/config/topology.yml"],
          commands: ["bundle exec ruby stack.rb dashboard"]
        )
      )
      view.component(
        preset.next_ideas_panel(
          ideas: ["Add topology replay mode"],
          empty_message: "No next ideas yet."
        )
      )
      view.component(
        preset.topology_flow_panel(diagram: "flowchart LR\ncamera-->edge")
      )
      view.component(
        preset.execution_flow_panel(diagram: "flowchart LR\nedge-->store")
      )
    end

    expect(html).to include("Main health")
    expect(html).to include("Realtime overview")
    expect(html).to include('data-chart-id="device-status"')
    expect(html).to include("Stream source /api/overview/stream")
    expect(html).to include('data-realtime-feed="true"')
    expect(html).to include('data-chat-prompt="Which devices are online right now?"')
    expect(html).to include("All activity")
    expect(html).to include("Open source API")
    expect(html).to include("Clear focus")
    expect(html).to include('data-device-id="front_door_cam"')
    expect(html).to include('data-notes-list="true"')
    expect(html).to include('data-chat-list="true"')
    expect(html).to include('data-camera-events-list="true"')
    expect(html).to include('data-activity-timeline="true"')
    expect(html).to include("Courier at the front door")
    expect(html).to include("Create Note")
    expect(html).to include("confirmation required")
    expect(html).to include("Confirm pending action")
    expect(html).to include("Dismiss")
    expect(html).to include("queued for confirmation just now")
    expect(html).to include("Recent Action Outcomes")
    expect(html).to include("Note ID")
    expect(html).to include("note-123")
    expect(html).to include("Proposed Payload")
    expect(html).to include("Result Payload")
    expect(html).to include("&quot;status&quot;: &quot;completed&quot;")
    expect(html).to include("&quot;type&quot;: &quot;create_note&quot;")
    expect(html).to include('data-action-status="confirmation_required"')
    expect(html).to include('data-action-status="completed"')
    expect(html).to include("Declared device inventory and current route targets.")
    expect(html).to include("Note save failed")
    expect(html).to include("Chat send failed")
    expect(html).to include("Save Note")
    expect(html).to include("Send to Igniter")
    expect(html).to include("Drilldown into the currently selected timeline item.")
    expect(html).to include("Declared health surfaces for the currently modelled app stack.")
    expect(html).to include("ready_app_surfaces=2/3")
    expect(html).to include("Ports, public endpoints, app edges, and topology notes.")
    expect(html).to include("Runtime-facing app roles, classes, commands, and dependencies.")
    expect(html).to include("Current workspace stores and local var files.")
    expect(html).to include("Useful entrypoints, file anchors, and local commands.")
    expect(html).to include("Likely next slices once this proving surface feels stable.")
    expect(html).to include("front_door_cam missed heartbeat")
    expect(html).to include("Mermaid view of devices, routes, and inter-app dependencies.")
    expect(html).to include("Mermaid view of ingest, shared stores, stack overview, and dashboard loop.")
    expect(html).to include("Topology Mermaid")
    expect(html).to include("Execution Mermaid")
  end

  it "exposes schema-authoring and submission-inspection surface presets" do
    schema = described_class.schema_authoring
    submission = described_class.submission_inspection

    expect(schema.theme_name).to eq(:companion)
    expect(schema.components).to include(:form_section, :banner, :action_bar, :schema_catalog, :submission_timeline)
    expect(schema.hooks.dig(:catalog)).to include("view_schema_catalog")
    expect(schema.authoring_catalog_panel {}).to be_a(Igniter::Frontend::Tailwind::UI::Panel)
    expect(schema.schema_create_form_section {}).to be_a(Igniter::Frontend::Tailwind::UI::FormSection)
    expect(schema.schema_patch_form_section {}).to be_a(Igniter::Frontend::Tailwind::UI::FormSection)
    expect(submission.theme_name).to eq(:companion)
    expect(submission.components).to include(:payload_diff, :key_value_list, :message_page, :submission_replay_actions, :submission_json_payload)
    expect(submission.hooks.dig(:payloads)).to include("raw_payload")
    expect(submission.submission_summary_panel {}).to be_a(Igniter::Frontend::Tailwind::UI::Panel)
    expect(submission.submission_replay_panel {}).to be_a(Igniter::Frontend::Tailwind::UI::Panel)
    expect(submission.submission_payload_panel(:raw) {}).to be_a(Igniter::Frontend::Tailwind::UI::Panel)
    expect(submission.submission_diff_panel {}).to be_a(Igniter::Frontend::Tailwind::UI::Panel)
    expect(submission.submission_detail_grid_class).to include("xl:grid-cols")
  end

  it "renders semantic authoring and submission content blocks from surface presets" do
    schema = described_class.schema_authoring
    submission = described_class.submission_inspection

    html = Igniter::Frontend.render do |view|
      schema.schema_catalog_intro(
        view,
        description: "Browse stored schemas.",
        catalog_path: "/api/views",
        featured_view_path: "/views/weekly-review",
        featured_view_label: "Open weekly review"
      )
      schema.schema_catalog_list(
        view,
        items: [
          {
            title: "Weekly Review",
            id: "weekly-review",
            meta: "version=1 · actions=save_review",
            view_path: "/views/weekly-review",
            api_path: "/api/views/weekly-review",
            load_action: "loadSchemaIntoEditor(\"weekly-review\")",
            clone_action: "cloneSchemaIntoEditor(\"weekly-review\")"
          }
        ],
        empty_message: "No schemas yet."
      )
      submission.submission_timeline(
        view,
        description: "Inspect recent runtime results.",
        items: [
          {
            title: "Weekly Review",
            href: "/submissions/sub-1",
            body: "action=save_review · status=processed · type=store_submission",
            meta: "submission=sub-1",
            action_label: "Schema JSON",
            action_href: "/api/views/weekly-review"
          }
        ],
        empty_message: "No submissions yet."
      )
      submission.submission_replay_actions(
        view,
        source_view_path: "/views/weekly-review",
        schema_path: "/api/views/weekly-review"
      )
      submission.submission_json_payload(view, { "highlight" => "Clearer priorities" })
    end

    expect(schema.schema_catalog_grid_class).to include("lg:grid-cols")
    expect(html).to include("Catalog JSON")
    expect(html).to include("Open weekly review")
    expect(html).to include("Load JSON")
    expect(html).to include("Clone")
    expect(html).to include("Inspect recent runtime results.")
    expect(html).to include("/submissions/sub-1")
    expect(html).to include("Open submission source view")
    expect(html).to include("Open schema JSON")
    expect(html).to include("&quot;highlight&quot;")
    expect(html).to include("Clearer priorities")
  end
end

RSpec.describe Igniter::Frontend::Tailwind::UI::Tokens do
  it "builds shared action, underline-link, and badge classes" do
    primary = described_class.action(variant: :primary, theme: :orange)
    ghost = described_class.action(variant: :ghost, theme: :amber, size: :sm, extra: "pill-link")
    underline = described_class.underline_link(theme: :amber, extra: "inline-flex")
    badge = described_class.badge(theme: :orange)

    expect(primary).to include("border-orange-300/20")
    expect(primary).to include("bg-orange-300/90")
    expect(ghost).to include("bg-white/5")
    expect(ghost).to include("pill-link")
    expect(underline).to include("text-amber-200")
    expect(underline).to include("underline-offset-4")
    expect(badge).to include("bg-orange-300/10")
    expect(badge).to include("text-orange-100")
  end
end
