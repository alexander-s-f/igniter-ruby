# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "fileutils"
require "spec_helper"
require_relative "../../packages/igniter-frontend/lib/igniter-frontend"

RSpec.describe "igniter-frontend local gem facade" do
  it "provides mounted-aware page rendering through frontend handlers" do
    page_class = Class.new do
      def self.render(context:, **)
        "<h1>#{context.fetch(:title)}</h1><p>#{context.route("/notes")}</p>"
      end
    end

    context_class = Class.new(Igniter::Frontend::Context)

    handler_class = Class.new(Igniter::Frontend::Handler) do
      define_method(:call) do
        render(page_class, context: build_context(context_class, title: "Frontend Home"))
      end
    end

    app_class = Class.new(Igniter::App) do
      include Igniter::Frontend::App

      root_dir Dir.pwd
      get "/", to: handler_class
    end

    status, headers, body = app_class.rack_app.call(
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "/dashboard",
      "PATH_INFO" => "/",
      "rack.input" => StringIO.new
    )

    html = body.each.to_a.join

    expect(status).to eq(200)
    expect(headers["Content-Type"]).to include("text/html")
    expect(html).to include("Frontend Home")
    expect(html).to include("/dashboard/notes")
  end

  it "adds scoped route helpers and request/response wrappers" do
    handler_class = Class.new(Igniter::Frontend::Handler) do
      define_method(:call) do
        json(
          {
            "path" => request.path,
            "query" => request.query_params,
            "params" => request.params,
            "stack" => app_access.stack
          }
        )
      end
    end

    app_class = Class.new(Igniter::App) do
      include Igniter::Frontend::App

      root_dir Dir.pwd

      scope "/notes" do
        post "/search", to: handler_class
      end
    end

    status, headers, body = app_class.rack_app.call(
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/notes/search",
      "QUERY_STRING" => "q=router",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "rack.input" => StringIO.new("page=2")
    )

    payload = JSON.parse(body.each.to_a.join)

    expect(status).to eq(200)
    expect(headers["Content-Type"]).to include("application/json")
    expect(payload.fetch("path")).to eq("/notes/search")
    expect(payload.fetch("query")).to eq({ "q" => "router" })
    expect(payload.fetch("params")).to include("q" => "router", "page" => "2")
    expect(payload.fetch("stack")).to eq({})
  end

  it "re-exports the current page and component lanes" do
    expect(Igniter::Frontend::ArbrePage).to eq(Igniter::Frontend::Arbre::TemplatePage)
    expect(Igniter::Frontend::Components).to eq(Igniter::Frontend::Arbre::Components)
  end

  it "serves the built-in runtime and app-owned javascript entrypoints" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "frontend"))
      File.write(File.join(dir, "frontend", "application.js"), "window.dashboardAppLoaded = true;\n")

      app_class = Class.new(Igniter::App) do
        include Igniter::Frontend::App

        root_dir dir
        frontend_assets path: "frontend"
      end

      runtime_status, runtime_headers, runtime_body = app_class.rack_app.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/__frontend/runtime.js",
        "rack.input" => StringIO.new
      )

      app_status, app_headers, app_body = app_class.rack_app.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/__frontend/assets/application.js",
        "rack.input" => StringIO.new
      )

      expect(runtime_status).to eq(200)
      expect(runtime_headers["Content-Type"]).to include("text/javascript")
      expect(runtime_body.each.to_a.join).to include("window.IgniterFrontend")
      expect(runtime_body.each.to_a.join).to include('register("tabs"')
      expect(runtime_body.each.to_a.join).to include('register("stream"')
      expect(runtime_body.each.to_a.join).to include("setTextTarget(name, value)")
      expect(runtime_body.each.to_a.join).to include("prependHtmlTarget(name, html, options = {})")

      expect(app_status).to eq(200)
      expect(app_headers["Content-Type"]).to include("text/javascript")
      expect(app_body.each.to_a.join).to include("window.dashboardAppLoaded = true;")
    end
  end
end
