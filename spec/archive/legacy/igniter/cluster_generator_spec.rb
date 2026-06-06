# frozen_string_literal: true

require "spec_helper"
require "igniter/app/scaffold_pack"
require "tmpdir"
require "yaml"

RSpec.describe Igniter::App::Generators::Cluster do
  it "layers a cluster-ready sandbox on top of the base scaffold" do
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        described_class.new("mesh_lab").generate

        expect(File.exist?("mesh_lab/apps/dashboard/app.rb")).to be true
        expect(File.exist?("mesh_lab/apps/dashboard/spec/dashboard_app_spec.rb")).to be true
        expect(File.exist?("mesh_lab/lib/mesh_lab/shared/node_identity_catalog.rb")).to be true
        expect(File.exist?("mesh_lab/lib/mesh_lab/shared/capability_profile.rb")).to be true
        expect(File.exist?("mesh_lab/lib/mesh_lab/shared/stack_overview.rb")).to be true
        expect(File.exist?("mesh_lab/lib/mesh_lab/shared/routing_demo.rb")).to be true
        expect(File.exist?("mesh_lab/apps/main/web/handlers/status_handler.rb")).to be true
        expect(File.exist?("mesh_lab/apps/main/support/cluster_ops_api.rb")).to be true
        expect(File.exist?("mesh_lab/apps/dashboard/web/handlers/home_handler.rb")).to be true
        expect(File.exist?("mesh_lab/apps/dashboard/web/handlers/overview_handler.rb")).to be true
        expect(File.exist?("mesh_lab/apps/dashboard/web/handlers/self_heal_demo_handler.rb")).to be true
        expect(File.exist?("mesh_lab/apps/dashboard/web/views/home_page.rb")).to be true

        stack = File.read("mesh_lab/stack.rb")
        stack_data = YAML.load_file("mesh_lab/stack.yml")
        readme = File.read("mesh_lab/README.md")
        main_app = File.read("mesh_lab/apps/main/app.rb")
        main_cluster_ops_api = File.read("mesh_lab/apps/main/support/cluster_ops_api.rb")
        dashboard_app = File.read("mesh_lab/apps/dashboard/app.rb")
        main_status_handler = File.read("mesh_lab/apps/main/web/handlers/status_handler.rb")
        dashboard_home_handler = File.read("mesh_lab/apps/dashboard/web/handlers/home_handler.rb")
        dashboard_overview_handler = File.read("mesh_lab/apps/dashboard/web/handlers/overview_handler.rb")
        dashboard_self_heal_handler = File.read("mesh_lab/apps/dashboard/web/handlers/self_heal_demo_handler.rb")
        dashboard_view = File.read("mesh_lab/apps/dashboard/web/views/home_page.rb")

        expect(stack).to include('mount :dashboard, at: "/dashboard"')
        expect(stack).to include("access_to: [:cluster_ops_api]")
        expect(stack_data.dig("stack", "default_node")).to eq("seed")
        expect(stack_data.fetch("nodes").keys).to contain_exactly("seed", "edge", "analyst")
        expect(stack_data.dig("nodes", "seed")).not_to have_key("role")
        expect(stack_data.dig("nodes", "edge")).not_to have_key("role")
        expect(stack_data.dig("nodes", "analyst")).not_to have_key("role")
        expect(stack_data.dig("nodes", "edge", "environment", "MESH_LAB_MOCK_CAPABILITIES")).to eq("piper_tts,whisper_asr")
        expect(readme).to include("generated with the `cluster` scaffold profile")
        expect(readme).to include("bin/console --node seed")
        expect(main_app).to include("host :cluster_app")
        expect(main_app).to include("CapabilityProfile.configure_cluster!")
        expect(main_app).to include("provide :cluster_ops_api, MeshLab::Main::Support::ClusterOpsAPI")
        expect(main_app).to include('require_relative "web/handlers/status_handler"')
        expect(main_app).to include('require_relative "support/cluster_ops_api"')
        expect(main_cluster_ops_api).to include("module ClusterOpsAPI")
        expect(main_cluster_ops_api).to include("Shared::StackOverview.build")
        expect(main_cluster_ops_api).to include("Shared::RoutingDemo.run!")
        expect(main_status_handler).to include('require_relative "../../../../lib/mesh_lab/shared/stack_overview"')
        expect(dashboard_app).to include("mount_operator_surface")
        expect(dashboard_app).to include('require_relative "web/handlers/self_heal_demo_handler"')
        expect(dashboard_app).to include('route "POST", "/demo/self-heal"')
        expect(dashboard_home_handler).to include('require_relative "../views/home_page"')
        expect(dashboard_home_handler).to include("DashboardApp.interface(:cluster_ops_api).overview")
        expect(dashboard_home_handler).to include("Views::HomePage.render")
        expect(dashboard_home_handler).not_to include("<!doctype html>")
        expect(dashboard_overview_handler).to include("DashboardApp.interface(:cluster_ops_api).overview")
        expect(dashboard_self_heal_handler).to include("DashboardApp.interface(:cluster_ops_api).run_self_heal_demo!")
        expect(dashboard_view).to include("Igniter::Frontend::Page")
        expect(dashboard_view).to include('render_document(view, title: "MeshLab Cluster Dashboard")')
      end
    end
  end
end
