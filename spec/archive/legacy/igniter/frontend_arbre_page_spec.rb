# frozen_string_literal: true

require "cgi"
require "spec_helper"
require "tmpdir"
require "igniter-frontend"

RSpec.describe "Igniter::Frontend::Arbre page authoring" do
  def build_fake_arbre
    Module.new do
      registry = {}
      const_set(:REGISTRY, registry)

      tag_class = Class.new do
        attr_reader :children

        def initialize(name = nil, parent = nil)
          @name = name
          @parent = parent
          @arbre_context = parent.respond_to?(:arbre_context) ? parent.arbre_context : self
          @children = []
          @attributes = {}
        end

        def self.builder_method(name)
          ::Arbre::REGISTRY[name.to_sym] = self
        end

        def build(attributes = {})
          apply_attributes(attributes)
          self
        end

        def <<(child)
          @children << child
          child
        end

        def add_child(child)
          self << child
        end

        def add_class(value)
          merged = [@attributes["class"], value].compact.join(" ").strip
          @attributes["class"] = merged unless merged.empty?
        end

        def set_attribute(name, value)
          @attributes[name.to_s] = value unless value.nil?
        end

        attr_reader :arbre_context

        def text_node(value)
          @children << CGI.escape_html(value.to_s)
        end

        def assigns
          return @assigns if instance_variable_defined?(:@assigns)
          return {} if arbre_context.equal?(self)

          arbre_context.respond_to?(:assigns) ? arbre_context.assigns : {}
        end

        def helpers
          return @helpers if instance_variable_defined?(:@helpers)
          return nil if arbre_context.equal?(self)

          arbre_context.respond_to?(:helpers) ? arbre_context.helpers : nil
        end

        def current_arbre_element
          return self if arbre_context.equal?(self)

          arbre_context.respond_to?(:current_arbre_element) ? arbre_context.current_arbre_element : self
        end

        def with_current_arbre_element(element, &block)
          if arbre_context.respond_to?(:with_current_arbre_element)
            arbre_context.with_current_arbre_element(element, &block)
          else
            yield
          end
        end

        def method_missing(name, *args, **kwargs, &block)
          if respond_to?(:current_arbre_element) && current_arbre_element && current_arbre_element != self &&
             current_arbre_element.respond_to?(name)
            return current_arbre_element.public_send(name, *args, **kwargs, &block)
          end

          return assigns[name.to_sym] if respond_to?(:assigns) && assigns.key?(name.to_sym)
          return helpers.public_send(name, *args, **kwargs, &block) if respond_to?(:helpers) && helpers&.respond_to?(name)

          component_class = ::Arbre::REGISTRY[name.to_sym]
          return build_component(component_class, *args, **kwargs, &block) if component_class

          tag(name, *args, **kwargs, &block)
        end

        def respond_to_missing?(name, include_private = false)
          ::Arbre::REGISTRY.key?(name.to_sym) || super
        end

        def tag(name, *args, **kwargs, &block)
          content, attributes = extract_content_and_attributes(args, kwargs)
          child = ::Arbre::Tag.new(name.to_s, self)
          child.build(attributes)
          child.text_node(content) unless content.nil?
          with_child_context(child) { child.instance_exec(&block) } if block
          self << child
        end

        def to_s
          render_node
        end

        private

        def build_component(component_class, *args, **kwargs, &block)
          initialize_arity = component_class.instance_method(:initialize).arity
          child = if initialize_arity.zero?
                    component_class.new
                  elsif initialize_arity == 1 || initialize_arity.negative?
                    component_class.new(arbre_context)
                  else
                    component_class.new(nil, self)
                  end
          child.parent = self if child.respond_to?(:parent=)
          self << child
          with_child_context(child) { child.build(*args, **kwargs, &block) }
          child
        end

        def with_child_context(child)
          return yield unless respond_to?(:with_current_arbre_element)

          with_current_arbre_element(child) { yield }
        end

        def apply_attributes(attributes)
          attributes.each do |key, value|
            next if value.nil?

            @attributes[key.to_s] = value
          end
        end

        def extract_content_and_attributes(args, kwargs)
          attributes = kwargs.dup
          content = nil

          if args.first.is_a?(Hash)
            attributes = args.shift.merge(attributes)
          elsif args.first
            content = args.shift
          end

          [content, attributes]
        end

        def render_node
          opening = +"<#{tag_name}"
          @attributes.each do |key, value|
            next if value.nil?

            escaped = CGI.escape_html(value.to_s)
            opening << %( #{key}="#{escaped}")
          end
          opening << ">"
          inner = @children.map { |child| child.is_a?(String) ? child : child.to_s }.join
          "#{opening}#{inner}</#{tag_name}>"
        end

        def tag_name
          @name || self.class.name.split("::").last.downcase
        end
      end

      const_set(:Tag, tag_class)

      context_class = Class.new(tag_class) do
        def initialize(assigns = {}, helpers = nil, &block)
          super(nil, nil)
          @assigns = assigns.transform_keys(&:to_sym)
          @helpers = helpers
          @current_arbre_element_buffer = [self]
          instance_exec(&block) if block
        end

        def to_s
          @children.map { |child| child.is_a?(String) ? child : child.to_s }.join
        end

        attr_reader :helpers, :assigns

        def current_arbre_element
          @current_arbre_element_buffer.last
        end

        def with_current_arbre_element(element)
          @current_arbre_element_buffer << element
          yield
        ensure
          @current_arbre_element_buffer.pop
        end
      end

      component_class = Class.new(tag_class) do
        def initialize(_name = nil, parent = nil)
          super(nil, parent)
        end
      end

      const_set(:Context, context_class)
      const_set(:Component, component_class)
    end
  end

  it "renders a developer-facing Arbre page shell around a fragment" do
    stub_const("Arbre", build_fake_arbre)

    html = Igniter::Frontend::Arbre::Page.render_page(title: "Order Details", theme: :companion) do
      nav("Home / Orders / Order 42", "aria-label": "Breadcrumb")

      article(class: "panel span-4") do
        h2 "Metadata"
        div "Compact developer-authored view"
        dl do
          dt "Created At"
          dd "2026-04-18"
          dt "Trace Id"
          dd { code "abc-123" }
        end
      end
    end

    expect(html).to include("<!DOCTYPE html>")
    expect(html).to include("@tailwindcss/browser@4")
    expect(html).to include('aria-label="Breadcrumb"')
    expect(html).to include(">Metadata<")
    expect(html).to include("Compact developer-authored view")
    expect(html).to include(">Created At<")
    expect(html).to include(">Trace Id<")
    expect(html).to include("<code")
    expect(html).to include("abc-123")
  end

  it "renders plain Arbre sections for developer-authored dashboards" do
    stub_const("Arbre", build_fake_arbre)

    html = Igniter::Frontend::Arbre::Page.render_page(title: "Lab", theme: :companion) do
      section(class: "hero") do
        div "Operator", class: "eyebrow"
        h1 "HomeLab"
        div "Developer-authored screen"
        div(class: "meta") do
          text_node "node=seed"
        end
        div(class: "actions") do
          a "Overview API", href: "/api/overview", class: "button secondary"
        end
        div "Last demo: healthy_lab", class: "ok"
      end

      article(class: "panel span-4") do
        h2 "Topology Health"
        span "healthy", class: "pill"
      end
    end

    expect(html).to include(">Operator<")
    expect(html).to include(">HomeLab<")
    expect(html).to include("Developer-authored screen")
    expect(html).to include("node=seed")
    expect(html).to include("Overview API")
    expect(html).to include("Last demo: healthy_lab")
    expect(html).to include("Topology Health")
    expect(html).to include(">healthy<")
    expect(html).to include('class="panel span-4"')
  end

  it "provides semantic action links and buttons inside action groups" do
    builder_calls = []
    builder = Object.new
    builder.define_singleton_method(:tag) do |name, content = nil, **attributes, &block|
      builder_calls << [name, content, attributes]
      block&.call
    end

    group = Igniter::Frontend::Arbre::Components::ActionGroup.new
    group.define_singleton_method(:current_builder) { builder }

    group.link "Overview API", href: "/api/overview", class_name: "pill-link"
    group.button "Refresh", type: "submit", class_name: "pill-button"

    expect(builder_calls).to include([:a, "Overview API", { href: "/api/overview", class: "pill-link" }])
    expect(builder_calls).to include([:button, "Refresh", { class: "pill-button", type: "submit" }])
  end

  it "renders semantic badges with inferred tones and compact sizes" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Badges", theme: :companion) do
      div class: "stack" do
        badge :active
        badge false
        badge "degraded", size: :sm
        badge "mesh route", tone: :accent, titleize: false, size: :xs
      end
    end

    expect(html).to include(">Active<")
    expect(html).to include(">No<")
    expect(html).to include(">Degraded<")
    expect(html).to include(">mesh route<")
    expect(html).to include("emerald-300/20")
    expect(html).to include("rose-300/20")
    expect(html).to include("amber-300/20")
    expect(html).to include("orange-300/20")
    expect(html).to include("text-[10px]")
  end

  it "renders card lines as badges, code, placeholders, and nested subcards" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Cards", theme: :companion) do
      card title: "Session", subtitle: "Runtime contract" do
        line :status, "joined", as: :badge
        line :capabilities, %w[memory routing], as: :badge, badge: { size: :sm }
        line :owner_url, nil, placeholder: "--"
        line :delivery_route, "mesh://edge-1", as: :code
        subcard "Details" do
          line :mode, :interactive
        end
      end
    end

    expect(html).to include(">Session<")
    expect(html).to include("Runtime contract")
    expect(html).to include(">Status<")
    expect(html).to include(">Joined<")
    expect(html).to include(">Memory<")
    expect(html).to include(">Routing<")
    expect(html).to include(">--<")
    expect(html).to include("mesh://edge-1")
    expect(html).to include(">Details<")
    expect(html).to include(">Interactive<")
  end

  it "renders compact semantic tables for collection-heavy operator views" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Events", theme: :companion) do
      table_with [
        { id: "evt-1", event: "ignite_joined", status: "joined", target: "edge-1", payload: "mesh://edge-1" },
        { id: "evt-2", event: "ignite_pending", status: "pending", target: "edge-2", payload: "mesh://edge-2" }
      ], title: "Recent Events", subtitle: "Operator-visible timeline", compact: true do |table|
        table.column :event
        table.column :status, as: :badge, badge: { size: :sm }
        table.column :target
        table.column :payload, as: :code
        table.actions do |row, actions|
          actions.link "Inspect", href: "/events/#{row.fetch(:id)}", class_name: "pill-link font-medium"
        end
      end
    end

    expect(html).to include(">Recent Events<")
    expect(html).to include("Operator-visible timeline")
    expect(html).to include(">ignite_joined<")
    expect(html).to include(">Joined<")
    expect(html).to include("mesh://edge-1")
    expect(html).to include('href="/events/evt-1"')
    expect(html).to include(">Inspect<")
  end

  it "renders an empty state row for semantic tables" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Empty", theme: :companion) do
      table_with [], empty_message: "No records yet." do |table|
        table.column :event
        table.column :status, as: :badge
      end
    end

    expect(html).to include("No records yet.")
    expect(html).to include("colspan=\"2\"")
  end

  it "renders structured viz views for hash, array, and object payloads" do
    value_object = Struct.new(:status, :target, keyword_init: true) do
      def to_h
        { status: status, target: target }
      end
    end

    html = Igniter::Frontend::Arbre::Page.render_page(title: "Viz", theme: :companion) do
      viz(
        {
          summary: value_object.new(status: :joined, target: "edge-1"),
          events: [{ id: "evt-1", state: "ready" }, { id: "evt-2", state: "pending" }],
          empty: [],
          enabled: true
        },
        title: "Snapshot",
        open: true,
        compact: true
      )
    end

    expect(html).to include(">Snapshot<")
    expect(html).to include("Hash")
    expect(html).to include("Array")
    expect(html).to include(">summary<")
    expect(html).to include(">events<")
    expect(html).to include(">enabled<")
    expect(html).to include(">Joined<")
    expect(html).to include("edge-1")
    expect(html).to include("Empty Array")
    expect(html).to include(">Yes<")
  end

  it "renders semantic filters with search, select, clear, and submit actions" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Filters", theme: :companion) do
      filters action: "/operator", method: "get", title: "Event Filters",
              subtitle: "Narrow noisy event streams.", values: { "q" => "ignite", "status" => "pending" },
              compact: true do |filter|
        filter.search "q", label: "Search", placeholder: "event or target"
        filter.select "status", label: "Status", options: %w[pending joined blocked]
        filter.clear "Reset", href: "/operator"
        filter.submit "Apply"
      end
    end

    expect(html).to include(">Event Filters<")
    expect(html).to include("Narrow noisy event streams.")
    expect(html).to include('action="/operator"')
    expect(html).to include('name="q"')
    expect(html).to include('value="ignite"')
    expect(html).to include('name="status"')
    expect(html).to include(">Reset<")
    expect(html).to include(">Apply<")
  end

  it "renders semantic pagination with summary and page links" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Pagination", theme: :companion) do
      pagination current_page: 2,
                 total_pages: 4,
                 total_count: 11,
                 per_page: 3,
                 item_name: "events",
                 href_builder: ->(page) { "/operator?events_page=#{page}" },
                 compact: true
    end

    expect(html).to include("Showing 4-6 of 11 events")
    expect(html).to include('href="/operator?events_page=1"')
    expect(html).to include('href="/operator?events_page=3"')
    expect(html).to include('aria-current="page"')
    expect(html).to include(">2<")
    expect(html).to include(">Previous<")
    expect(html).to include(">Next<")
  end

  it "renders a sidebar shell with sections and routed content" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Shell", theme: :companion) do
      sidebar_shell title: "Companion",
                    subtitle: "Operator proving ground",
                    summary_items: [
                      { label: "Root App", value: "main" },
                      { label: "Generated", value: "2026-04-21T08:00:00Z" }
                    ],
                    sections: [
                      {
                        title: "Workspace",
                        items: [
                          { label: "Operator Desk", href: "/", current: true, meta: "home" },
                          { label: "Operator Console", href: "/operator", meta: "built-in" }
                        ]
                      }
                    ] do
        panel title: "Main Content" do
          div "Shell-routed content"
        end
      end
    end

    expect(html).to include(">Companion<")
    expect(html).to include("Operator proving ground")
    expect(html).to include(">Workspace<")
    expect(html).to include('href="/operator"')
    expect(html).to include('aria-current="page"')
    expect(html).to include(">Main Content<")
    expect(html).to include("Shell-routed content")
  end

  it "renders polished breadcrumbs for app navigation" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Breadcrumbs", theme: :companion) do
      breadcrumbs class_name: "mb-5" do |trail|
        trail.crumb "Companion", "/"
        trail.crumb "Dashboard", "/dashboard"
        trail.crumb "Operator Desk", current: true
      end
    end

    expect(html).to include('aria-label="Breadcrumb"')
    expect(html).to include('href="/dashboard"')
    expect(html).to include(">Operator Desk<")
    expect(html).to include("rounded-full border border-white/10 bg-white/[0.04]")
  end

  it "renders semantic value primitives for booleans, dates, indicators, numbers, and percentages" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Values", theme: :companion) do
      div class: "grid gap-3" do
        boolean true
        datetime "2026-04-21T10:30:00Z"
        indicator :ready
        number 12_345
        percentage 0.825
      end
    end

    expect(html).to include(">Yes<")
    expect(html).to include("2026-04-21 10:30 UTC")
    expect(html).to include(">Ready<")
    expect(html).to include("12,345")
    expect(html).to include("82.5%")
  end

  it "renders empty and loading state primitives" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "States", theme: :companion) do
      empty_state "No events yet", message: "Live runtime activity will appear here."
      loading_state "Loading activity", message: "Connecting to stream.", lines: 2
    end

    expect(html).to include(">No events yet<")
    expect(html).to include("Live runtime activity will appear here.")
    expect(html).to include(">Loading activity<")
    expect(html).to include("Connecting to stream.")
    expect(html).to include("animate-pulse")
  end

  it "renders card and table values through semantic display types" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Typed Values", theme: :companion) do
      card title: "Signals" do
        line :status, :ready, as: :indicator
        line :public, true, as: :boolean
        line :generated_at, "2026-04-21T10:30:00Z", as: :datetime
        line :notes_count, 42, as: :number
        line :coverage, 0.5, as: :percentage
      end

      table_with [{ name: "main", public: true, coverage: 0.75 }], compact: true do |table|
        table.column :name
        table.column :public, as: :boolean
        table.column :coverage, as: :percentage
      end
    end

    expect(html).to include(">Signals<")
    expect(html).to include(">Ready<")
    expect(html).to include(">Yes<")
    expect(html).to include("42")
    expect(html).to include("50.0%")
    expect(html).to include("75.0%")
  end

  it "renders shell columns with explicit main and aside lanes" do
    html = Igniter::Frontend::Arbre::Page.render_page(title: "Columns", theme: :companion) do
      shell_columns do |columns|
        columns.main do
          panel title: "Main Lane" do
            div "Primary content"
          end
        end

        columns.aside do
          panel title: "Aside Lane" do
            div "Secondary content"
          end
        end
      end
    end

    expect(html).to include("xl:grid-cols-[minmax(0,1.2fr)_minmax(320px,0.8fr)]")
    expect(html).to include(">Main Lane<")
    expect(html).to include(">Aside Lane<")
    expect(html).to include("Primary content")
    expect(html).to include("Secondary content")
  end

  it "renders an Arbre template with layout and page helpers" do
    stub_const("Arbre", build_fake_arbre)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "layout.arb"), <<~ARB)
        html do
          body do
            section class: "layout-shell" do
              h1 page_title
              render_template_content
            end
          end
        end
      ARB

      File.write(File.join(dir, "home_page.arb"), <<~ARB)
        article class: "summary" do
          h2 page_context.fetch(:title)
          div helper_summary
        end
      ARB

      page_class = Class.new(Igniter::Frontend::ArbrePage) do
        template_root dir
        template "home_page"
        layout "layout"

        def initialize(context:)
          @context = context
        end

        def template_locals
          { page_context: @context }
        end

        def page_title
          "Human Home"
        end

        def helper_summary
          "Developer-authored template"
        end
      end

      html = page_class.render(context: { title: "Lab Overview" })

      expect(html).to include("Human Home")
      expect(html).to include("Lab Overview")
      expect(html).to include("Developer-authored template")
      expect(html).to include("layout-shell")
      expect(html).to include("summary")
    end
  end

  it "renders mounted frontend javascript tags from the layout" do
    stub_const("Arbre", build_fake_arbre)

    route_context = Struct.new(:base_path) do
      def route(suffix)
        "#{base_path}#{suffix}"
      end
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "layout.arb"), <<~ARB)
        html do
          body do
            render_template_content
            render_frontend_javascript "application"
          end
        end
      ARB

      File.write(File.join(dir, "home_page.arb"), <<~ARB)
        article class: "summary" do
          h2 "Frontend JS"
        end
      ARB

      page_class = Class.new(Igniter::Frontend::ArbrePage) do
        template_root dir
        template "home_page"
        layout "layout"

        def initialize(context:)
          @context = context
        end
      end

      html = page_class.render(context: route_context.new("/dashboard"))

      expect(html).to include("/dashboard/__frontend/runtime.js")
      expect(html).to include("/dashboard/__frontend/assets/application.js")
      expect(html).to include("summary")
    end
  end

  it "exposes stream target helper for templates and components" do
    stub_const("Arbre", build_fake_arbre)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "layout.arb"), <<~ARB)
        html do
          body do
            render_template_content
          end
        end
      ARB

      File.write(File.join(dir, "home_page.arb"), <<~ARB)
        article(**stream_target(:activity_feed, id: "activity-feed")) do
          div "Live feed"
        end
      ARB

      page_class = Class.new(Igniter::Frontend::ArbrePage) do
        template_root dir
        template "home_page"
        layout "layout"

        def initialize(context:)
          @context = context
        end
      end

      html = page_class.render(context: {})

      expect(html).to include('id="activity-feed"')
      expect(html).to include('data-ig-stream-target="activity-feed"')
    end
  end

  it "exposes controller value helpers with JSON serialization for templates" do
    stub_const("Arbre", build_fake_arbre)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "layout.arb"), <<~ARB)
        html do
          body do
            main(
              "data-ig-controller": "stream",
              **stream_value(:url, "/api/overview/stream"),
              **stream_value(:events, %w[overview activity]),
              **stream_value(:hook, "homeLabOverviewStream")
            ) do
              render_template_content
            end
          end
        end
      ARB

      File.write(File.join(dir, "home_page.arb"), <<~ARB)
        article do
          div "Frontend values"
        end
      ARB

      page_class = Class.new(Igniter::Frontend::ArbrePage) do
        template_root dir
        template "home_page"
        layout "layout"

        def initialize(context:)
          @context = context
        end
      end

      html = page_class.render(context: {})

      expect(html).to include('data-ig-stream-url-value="/api/overview/stream"')
      expect(html).to include('data-ig-stream-events-value="[&quot;overview&quot;,&quot;activity&quot;]"')
      expect(html).to include('data-ig-stream-hook-value="homeLabOverviewStream"')
    end
  end

  it "exposes controller scope helpers for templates" do
    stub_const("Arbre", build_fake_arbre)

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "layout.arb"), <<~ARB)
        html do
          body do
            main(
              **controller_scope(:stream, :operator_panel),
              **stream_value(:hook, "homeLabOverviewStream")
            ) do
              render_template_content
            end
          end
        end
      ARB

      File.write(File.join(dir, "home_page.arb"), <<~ARB)
        article do
          div "Controller scope"
        end
      ARB

      page_class = Class.new(Igniter::Frontend::ArbrePage) do
        template_root dir
        template "home_page"
        layout "layout"

        def initialize(context:)
          @context = context
        end
      end

      html = page_class.render(context: {})

      expect(html).to include('data-ig-controller="stream operator-panel"')
      expect(html).to include('data-ig-stream-hook-value="homeLabOverviewStream"')
    end
  end
end
