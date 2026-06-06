# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Web do
  it "builds an application skeleton with route and api declarations" do
    app = described_class.application do
      get "/", to: "Pages::Home"
      post "/messages", to: "Actions::Messages::Create"
      stream "/messages/stream", to: "Projections::Messages"
    end

    expect(app.routes.map { |route| [route.verb, route.path, route.target] }).to eq(
      [
        [:get, "/", "Pages::Home"],
        [:post, "/messages", "Actions::Messages::Create"]
      ]
    )
    expect(app.api_surface.endpoints.map { |endpoint| [endpoint.kind, endpoint.verb, endpoint.path, endpoint.target] }).to eq(
      [
        [:stream, :get, "/messages/stream", "Projections::Messages"]
      ]
    )
  end

  it "supports compact root and page authoring DSL" do
    app = described_class.application do
      root title: "Operator" do
        main do
          h1 "Operator"
        end
      end

      page "/projects/:id", title: "Project" do
        main do
          h1 assigns[:project_name]
          para assigns[:status]
        end
      end
    end

    root_route, project_route = app.routes

    expect(root_route.verb).to eq(:get)
    expect(root_route.path).to eq("/")
    expect(root_route.target).to be < Igniter::Web::Page
    expect(root_route.metadata).to include(page: true, title: "Operator")

    expect(project_route.verb).to eq(:get)
    expect(project_route.path).to eq("/projects/:id")
    expect(project_route.target).to be < Igniter::Web::Page
    expect(project_route.target.render(assigns: { project_name: "Atlas", status: "active" })).to include("Atlas")
    expect(project_route.target.render(assigns: { project_name: "Atlas", status: "active" })).to include("Project")
  end

  it "builds a contracts-first api skeleton" do
    api = described_class.api do
      command "/projects/:id/advance", to: Igniter::Web.contract("Contracts::AdvanceProject")
      query "/projects/:id", to: Igniter::Web.service(:project_snapshot)
      webhook "/mesh/events", to: "Ingress::MeshEvents", auth: :signature
    end

    expect(api.endpoints.map { |endpoint| [endpoint.kind, endpoint.verb, endpoint.path, endpoint.target] }).to eq(
      [
        [:command, :post, "/projects/:id/advance", Igniter::Web.contract("Contracts::AdvanceProject")],
        [:query, :get, "/projects/:id", Igniter::Web.service(:project_snapshot)],
        [:webhook, :post, "/mesh/events", "Ingress::MeshEvents"]
      ]
    )
    expect(api.endpoints.first.target.to_h).to include(kind: :contract, name: "Contracts::AdvanceProject")
    expect(api.endpoints[1].target.to_h).to include(kind: :service, name: "project_snapshot")
    expect(api.endpoints.last.metadata).to eq({ auth: :signature })
  end

  it "provides an adapter-oriented record skeleton" do
    record_class = Class.new(Igniter::Web::Record) do
      adapter :memory
      attribute :title, :string
      attribute :status, :symbol, default: :draft
    end

    record = record_class.new(title: "Launch", status: :active)

    expect(record_class.adapter_definition).to eq(name: :memory, options: {})
    expect(record_class.attribute_definitions.map { |definition| [definition[:name], definition[:type]] }).to eq(
      [%i[title string], %i[status symbol]]
    )
    expect(record[:title]).to eq("Launch")
    expect(record.to_h).to eq(title: "Launch", status: :active)
  end

  it "wraps web applications in a Rack-compatible application mount" do
    web = described_class.application do
      root title: "Operator" do
        main do
          h1 "Operator"
        end
      end
    end

    mount = described_class.mount(:operator, path: "/operator", application: web, metadata: { audience: :operator })
    status, headers, body = mount.rack_app.call("PATH_INFO" => "/operator")

    expect(status).to eq(200)
    expect(headers.fetch("content-type")).to include("text/html")
    expect(body.join).to include("Operator")
    expect(mount.to_h).to include(name: :operator, path: "/operator", metadata: { audience: :operator })
    expect(mount.to_h.fetch(:routes).first).to include(verb: :get, path: "/")
  end

  it "passes a mount context into mounted pages" do
    environment = Igniter::Application.build_kernel
                                      .manifest(:operator, root: "/tmp/operator", env: :test)
                                      .mount_web(:operator, Struct.new(:name).new("OperatorMount"),
                                                 at: "/operator", capabilities: %i[screen stream])
                                      .provide(:cluster_status, -> { "healthy" })
                                      .then { |kernel| Igniter::Application::Environment.new(profile: kernel.finalize) }
    web = described_class.application do
      root title: "Operator" do
        main do
          h1 assigns[:ctx].manifest.name
          para assigns[:ctx].route("/events")
          para assigns[:ctx].service(:cluster_status).call
          para assigns[:ctx].capabilities.join(",")
        end
      end
    end

    mount = described_class.mount(:operator, path: "/operator", application: web, environment: environment)
    _status, _headers, body = mount.rack_app.call("PATH_INFO" => "/operator")
    html = body.join

    expect(html).to include("operator")
    expect(html).to include("/operator/events")
    expect(html).to include("healthy")
    expect(html).to include("screen,stream")
  end

  it "binds a finalized application environment without mutating the original mount" do
    web = described_class.application do
      root title: "Operator" do
        main do
          h1 assigns[:ctx].manifest.name
          para assigns[:ctx].service(:cluster_status).call
          para assigns[:ctx].capabilities.join(",")
        end
      end
    end
    mount = described_class.mount(:operator, path: "/operator", application: web)

    kernel = Igniter::Application.build_kernel
    kernel.manifest(:operator, root: "/tmp/operator", env: :test)
    kernel.provide(:cluster_status, -> { "green" })
    kernel.mount_web(:operator, mount, at: "/operator", capabilities: %i[screen stream])
    environment = Igniter::Application::Environment.new(profile: kernel.finalize)

    bound_mount = mount.bind(environment: environment)

    expect(mount.context.manifest).to be_nil
    expect(bound_mount.context.manifest.name).to eq(:operator)
    expect(bound_mount.context.service(:cluster_status).call).to eq("green")
    expect(bound_mount.context.capabilities).to eq(%i[screen stream])

    status, _headers, body = bound_mount.rack_app.call("PATH_INFO" => "/operator")
    expect(status).to eq(200)
    expect(body.join).to include("green")
    expect(body.join).to include("screen,stream")
  end

  it "derives web-owned surface structure from application layout profiles" do
    capsule = Igniter::Application.blueprint(
      name: :operator,
      root: "/tmp/operator",
      layout_profile: :capsule,
      web_surfaces: [:operator_console]
    )
    standalone = Igniter::Application.blueprint(
      name: :console,
      root: "/tmp/console",
      layout_profile: :standalone,
      web_surfaces: [:operator_console]
    )

    capsule_structure = described_class.surface_structure(capsule)
    standalone_structure = described_class.surface_structure(standalone)

    expect(capsule_structure.web_root).to eq("web")
    expect(capsule_structure.path(:screens)).to eq("web/screens")
    expect(standalone_structure.web_root).to eq("app/web")
    expect(standalone_structure.path(:screens)).to eq("app/web/screens")
    expect(capsule_structure.groups).to eq(%i[screens pages components projections webhooks assets])
    expect(capsule_structure.to_h.fetch(:metadata)).to include(application: :operator)
  end

  it "describes web surface exports and imports without controller state" do
    app = described_class.application do
      root title: "Operator" do
        main { h1 "Operator" }
      end

      command "/incidents/:id/resolve", to: Igniter::Web.contract("Contracts::ResolveIncident")
      query "/status", to: Igniter::Web.service(:cluster_status)
      stream "/events", to: Igniter::Web.projection("Projections::ClusterEvents")

      screen :execution, intent: :live_process do
        ask :review_note,
            as: :textarea,
            required: true,
            resume_with: Igniter::Web.service(:review_session),
            schema: { min_length: 10 }
        stream :events, from: "Projections::ClusterEvents"
        chat with: "Agents::ProjectLead", purpose: :review_support
        action :pause,
               run: "Contracts::PauseProject",
               purpose: :operator_control,
               payload_schema: { reason: :string }
      end

      screen_route "/execution", :execution
    end

    manifest = described_class.surface_manifest(app, name: :operator, path: "/operator")
    exports = manifest.exports.map { |entry| [entry.fetch(:kind), entry[:path] || entry[:name]] }
    imports = manifest.imports.map { |entry| [entry.fetch(:kind), entry.fetch(:name)] }
    interactions = manifest.to_h.fetch(:interactions)

    expect(exports).to include([:page, "/"], [:screen, "/execution"], [:command, "/incidents/:id/resolve"])
    expect(exports).to include([:query, "/status"], [:stream, "/events"], %i[screen execution])
    expect(imports).to include(
      [:contract, "Contracts::ResolveIncident"],
      [:service, "cluster_status"],
      [:projection, "Projections::ClusterEvents"],
      [:contract, "Contracts::PauseProject"],
      [:agent, "Agents::ProjectLead"]
    )
    expect(interactions.fetch(:pending_inputs).first).to include(
      name: :review_note,
      input_type: :textarea,
      required: true,
      target: { kind: :service, name: "review_session", metadata: {} },
      schema: { min_length: 10 },
      source: include(kind: :screen, screen: :execution, element: :ask)
    )
    expect(interactions.fetch(:pending_actions).first).to include(
      name: :pause,
      action_type: :command,
      target: "Contracts::PauseProject",
      role: :primary_action,
      purpose: :operator_control,
      payload_schema: { reason: :string },
      source: include(kind: :screen, screen: :execution, element: :action)
    )
    expect(interactions.fetch(:streams).first).to include(
      name: :events,
      from: "Projections::ClusterEvents",
      source: include(kind: :screen, screen: :execution, element: :stream)
    )
    expect(interactions.fetch(:chats).first).to include(
      name: :"Agents::ProjectLead",
      with: "Agents::ProjectLead",
      metadata: { purpose: :review_support }
    )
    expect(manifest.to_h).to include(name: :operator, path: "/operator")
    expect(manifest.to_capsule_export).to include(
      name: :operator,
      kind: :web_surface,
      target: "/operator"
    )
    expect(manifest.to_capsule_export.fetch(:metadata).fetch(:surface_manifest)).to include(
      name: :operator,
      path: "/operator"
    )
  end

  it "adapts web interaction metadata into application flow pending state hashes" do
    app = described_class.application do
      screen :execution, intent: :live_process do
        ask :review_note,
            as: :textarea,
            required: true,
            resume_with: Igniter::Web.service(:review_session),
            schema: { min_length: 10 }
        action :pause,
               run: "Contracts::PauseProject",
               action_type: :contract,
               purpose: :operator_control,
               payload_schema: { reason: :string }
      end
    end

    manifest = described_class.surface_manifest(app, name: :operator, path: "/operator")
    pending_state = described_class.flow_pending_state(
      manifest,
      current_step: :execution,
      metadata: { surface: :operator }
    )

    expect(pending_state.fetch(:pending_inputs).first).to include(
      name: :review_note,
      input_type: :textarea,
      required: true,
      target: :execution,
      schema: { min_length: 10 },
      metadata: include(
        surface: :operator,
        source: include(screen: :execution, element: :ask),
        web_interaction: include(name: :review_note)
      )
    )
    expect(pending_state.fetch(:pending_actions).first).to include(
      name: :pause,
      action_type: :contract,
      target: "Contracts::PauseProject",
      payload_schema: { reason: :string },
      metadata: include(
        surface: :operator,
        purpose: :operator_control,
        source: include(screen: :execution, element: :action),
        web_interaction: include(name: :pause)
      )
    )
  end

  it "projects web surface metadata against app-owned flow declarations and feature slices" do
    app = described_class.application do
      screen :incident_review, intent: :human_decision do
        ask :clarification, as: :textarea
        action :approve_plan, run: "Contracts::ResolveIncident", action_type: :contract
      end

      screen_route "/incident-review", :incident_review
    end
    surface = described_class.surface_manifest(app, name: :operator_console, path: "/operator")
    declaration = {
      name: :incident_review,
      initial_status: :waiting_for_user,
      current_step: :review_plan,
      pending_inputs: [
        { name: :clarification, input_type: :textarea, target: :review_plan }
      ],
      pending_actions: [
        { name: :approve_plan, action_type: :contract, target: "Contracts::ResolveIncident" }
      ],
      surfaces: [:operator_console]
    }
    feature = {
      name: :incidents,
      flows: [:incident_review],
      surfaces: [:operator_console]
    }

    projection = described_class.flow_surface_projection(surface, declaration: declaration, feature: feature)

    expect(projection).to include(
      status: :aligned,
      surface: { name: :operator_console, path: "/operator" },
      flow: include(name: :incident_review, initial_status: :waiting_for_user),
      feature: include(name: :incidents)
    )
    expect(projection.fetch(:pending_inputs)).to include(
      matched: [:clarification],
      missing_in_surface: [],
      extra_in_surface: []
    )
    expect(projection.fetch(:pending_actions)).to include(
      matched: [:approve_plan],
      missing_in_surface: [],
      extra_in_surface: []
    )
    expect(projection.fetch(:relationships)).to include(
      declaration_references_surface: true,
      feature_references_surface: true,
      feature_references_flow: true
    )

    surface_metadata = described_class.flow_surface_metadata(surface, declaration: declaration, feature: feature)

    expect(surface_metadata).to include(
      name: :operator_console,
      kind: :web_surface,
      status: :aligned,
      flows: [:incident_review],
      features: [:incidents]
    )
    expect(surface_metadata.fetch(:projections).fetch(:flow_surface)).to include(
      status: :aligned,
      surface: { name: :operator_console, path: "/operator" }
    )
  end

  it "handles nested mounted paths and missing routes" do
    web = described_class.application do
      page "/nested", title: "Nested" do
        main do
          h1 "Nested"
        end
      end
    end
    mount = described_class.mount(:operator, path: "/operator", application: web)

    nested_status, _nested_headers, nested_body = mount.rack_app.call("PATH_INFO" => "/operator/nested")
    missing_status, _missing_headers, missing_body = mount.rack_app.call("PATH_INFO" => "/operator/missing")

    expect(nested_status).to eq(200)
    expect(nested_body.join).to include("Nested")
    expect(missing_status).to eq(404)
    expect(missing_body.join).to include("No igniter-web route for /missing")
  end
end
