# frozen_string_literal: true

require "spec_helper"
require "igniter/app/scaffold_pack"
require "tmpdir"
require "yaml"

RSpec.describe Igniter::App::Generators::Dashboard do
  it "layers a mounted dashboard on top of the base scaffold" do
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        described_class.new("my_hub").generate

        expect(File.exist?("my_hub/apps/dashboard/app.rb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/app.yml")).to be true
        expect(File.exist?("my_hub/apps/dashboard/spec/dashboard_app_spec.rb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/support/stack_overview.rb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/contexts/home_context.rb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/web/handlers/home_handler.rb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/web/views/home_page.rb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/web/views/layout.arb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/web/views/home_page.arb")).to be true
        expect(File.exist?("my_hub/apps/dashboard/frontend/application.js")).to be true

        stack = File.read("my_hub/stack.rb")
        stack_data = YAML.load_file("my_hub/stack.yml")
        readme = File.read("my_hub/README.md")
        dashboard_app = File.read("my_hub/apps/dashboard/app.rb")
        dashboard_context = File.read("my_hub/apps/dashboard/contexts/home_context.rb")
        dashboard_handler = File.read("my_hub/apps/dashboard/web/handlers/home_handler.rb")
        dashboard_support = File.read("my_hub/apps/dashboard/support/stack_overview.rb")
        dashboard_view = File.read("my_hub/apps/dashboard/web/views/home_page.rb")
        dashboard_layout_template = File.read("my_hub/apps/dashboard/web/views/layout.arb")
        dashboard_home_template = File.read("my_hub/apps/dashboard/web/views/home_page.arb")
        dashboard_frontend = File.read("my_hub/apps/dashboard/frontend/application.js")

        expect(stack).to include('require_relative "apps/dashboard/app"')
        expect(stack).to include('mount :dashboard, at: "/dashboard"')
        expect(stack_data).not_to have_key("stack")
        expect(stack_data).not_to have_key("nodes")
        expect(stack_data.dig("server", "port")).to eq(4567)
        expect(readme).to include("generated with the `dashboard` scaffold profile")
        expect(readme).to include("http://127.0.0.1:4567/dashboard")
        expect(readme).to include("contexts/home_context.rb")
        expect(readme).to include("home_page.arb")
        expect(dashboard_app).to include("include Igniter::Frontend::App")
        expect(dashboard_app).to include('frontend_assets path: "frontend"')
        expect(dashboard_app).to include('get "/", to: MyHub::Dashboard::Web::Handlers::HomeHandler')
        expect(dashboard_app).to include("mount_operator_surface")
        expect(dashboard_app).to include('require_relative "web/handlers/home_handler"')
        expect(dashboard_context).to include("class HomeContext < Igniter::Frontend::Context")
        expect(dashboard_handler).to include("class HomeHandler < Igniter::Frontend::Handler")
        expect(dashboard_handler).to include("build_context(")
        expect(dashboard_handler).to include("Contexts::HomeContext")
        expect(dashboard_handler).to include("render(")
        expect(dashboard_handler).to include('require_relative "../../support/stack_overview"')
        expect(dashboard_handler).to include('require_relative "../../contexts/home_context"')
        expect(dashboard_handler).to include('require_relative "../views/home_page"')
        expect(dashboard_view).to include("Igniter::Frontend::ArbrePage")
        expect(dashboard_view).to include('template "home_page"')
        expect(dashboard_view).to include('layout "layout"')
        expect(dashboard_layout_template).to include("tailwind_cdn_url")
        expect(dashboard_layout_template).to include('render_frontend_javascript "application"')
        expect(dashboard_home_template).to include("page_context.summary_metrics")
        expect(dashboard_home_template).to include('page_context.route("/api/operator")')
        expect(dashboard_support).to include("module Dashboard")
        expect(dashboard_support).not_to include("module Shared")
        expect(dashboard_frontend).to include("igniterDashboard")
      end
    end
  end
end
