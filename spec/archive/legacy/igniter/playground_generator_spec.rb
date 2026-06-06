# frozen_string_literal: true

require "spec_helper"
require "igniter/app/scaffold_pack"
require "tmpdir"
require "yaml"

RSpec.describe Igniter::App::Generators::Playground do
  it "layers a playground profile on top of the base scaffold" do
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        described_class.new("my_lab").generate

        expect(File.exist?("my_lab/apps/dashboard/app.rb")).to be true
        expect(File.exist?("my_lab/apps/dashboard/app.yml")).to be true
        expect(File.exist?("my_lab/apps/dashboard/spec/dashboard_app_spec.rb")).to be true
        expect(File.exist?("my_lab/bin/console")).to be true
        expect(File.exist?("my_lab/apps/main/support/notes_api.rb")).to be true
        expect(File.exist?("my_lab/apps/main/support/playground_ops_api.rb")).to be true
        expect(File.exist?("my_lab/lib/my_lab/shared/stack_overview.rb")).to be true
        expect(File.exist?("my_lab/lib/my_lab/shared/note_store.rb")).to be true
        expect(File.exist?("my_lab/apps/main/web/handlers/status_handler.rb")).to be true
        expect(File.exist?("my_lab/apps/main/web/handlers/notes_list_handler.rb")).to be true
        expect(File.exist?("my_lab/apps/main/web/handlers/notes_create_handler.rb")).to be true
        expect(File.exist?("my_lab/apps/dashboard/web/handlers/home_handler.rb")).to be true
        expect(File.exist?("my_lab/apps/dashboard/web/handlers/notes_create_handler.rb")).to be true
        expect(File.exist?("my_lab/apps/dashboard/web/handlers/overview_handler.rb")).to be true
        expect(File.exist?("my_lab/apps/dashboard/web/views/home_page.rb")).to be true

        stack = File.read("my_lab/stack.rb")
        stack_data = YAML.load_file("my_lab/stack.yml")
        readme = File.read("my_lab/README.md")
        main_app = File.read("my_lab/apps/main/app.rb")
        dashboard_app = File.read("my_lab/apps/dashboard/app.rb")
        main_notes_api = File.read("my_lab/apps/main/support/notes_api.rb")
        main_playground_ops_api = File.read("my_lab/apps/main/support/playground_ops_api.rb")
        main_status_handler = File.read("my_lab/apps/main/web/handlers/status_handler.rb")
        dashboard_handler = File.read("my_lab/apps/dashboard/web/handlers/home_handler.rb")
        dashboard_notes_create_handler = File.read("my_lab/apps/dashboard/web/handlers/notes_create_handler.rb")
        dashboard_overview_handler = File.read("my_lab/apps/dashboard/web/handlers/overview_handler.rb")
        dashboard_page = File.read("my_lab/apps/dashboard/web/views/home_page.rb")

        expect(stack).to include('require_relative "apps/dashboard/app"')
        expect(stack).to include('app :dashboard, path: "apps/dashboard", klass: MyLab::DashboardApp')
        expect(stack).to include("access_to: [:notes_api, :playground_ops_api]")
        expect(stack).to include(":playground_ops_api")
        expect(stack).to include('mount :dashboard, at: "/dashboard"')
        expect(stack_data).not_to have_key("stack")
        expect(stack_data).not_to have_key("nodes")
        expect(stack_data.dig("server", "port")).to eq(4567)
        expect(readme).to include("generated with the `playground` profile")
        expect(readme).to include("shared notes flow")
        expect(readme).to include("http://127.0.0.1:4567/dashboard")
        expect(readme).to include("bin/console")
        expect(readme).not_to include("bin/start --node main")
        expect(readme).to include("var/log/dev/*.log")
        expect(main_app).to include('route "POST", "/v1/notes"')
        expect(main_app).to include('require_relative "support/notes_api"')
        expect(main_app).to include('require_relative "support/playground_ops_api"')
        expect(main_app).to include("provide :notes_api, MyLab::Main::Support::NotesAPI")
        expect(main_app).to include("provide :playground_ops_api, MyLab::Main::Support::PlaygroundOpsAPI")
        expect(main_notes_api).to include("module NotesAPI")
        expect(main_notes_api).to include("MyLab::Shared::NoteStore")
        expect(main_playground_ops_api).to include("module PlaygroundOpsAPI")
        expect(main_playground_ops_api).to include("MyLab::Shared::StackOverview.build")
        expect(main_app).to include('require_relative "web/handlers/status_handler"')
        expect(main_status_handler).to include('require_relative "../../../../lib/my_lab/shared/stack_overview"')
        expect(dashboard_app).to include("mount_operator_surface")
        expect(dashboard_app).to include('require_relative "web/handlers/home_handler"')
        expect(dashboard_handler).to include('require_relative "../views/home_page"')
        expect(dashboard_handler).to include("DashboardApp.interface(:playground_ops_api).overview")
        expect(dashboard_notes_create_handler).to include("DashboardApp.interface(:notes_api).add")
        expect(dashboard_notes_create_handler).to include("DashboardApp.interface(:playground_ops_api).overview")
        expect(dashboard_overview_handler).to include("DashboardApp.interface(:playground_ops_api).overview")
        expect(dashboard_page).to include("Operator Console")
        expect(dashboard_app).to include('route "POST", "/notes"')
        expect(dashboard_page).to include("Operator API")
        expect(dashboard_page).to include('action: route("/notes")')
      end
    end
  end

  it "uses a local monorepo path dependency for playground scaffolds inside the repo" do
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        FileUtils.mkdir_p("lib/igniter")

        described_class.new("playgrounds/home-lab").generate

        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter", path: "../.."')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-core", path: "../../packages/igniter-core"')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-agents", path: "../../packages/igniter-agents"')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-ai", path: "../../packages/igniter-ai"')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-sdk", path: "../../packages/igniter-sdk"')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-app", path: "../../packages/igniter-app"')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-server", path: "../../packages/igniter-server"')
        expect(File.read("playgrounds/home-lab/Gemfile")).to include('gem "igniter-cluster", path: "../../packages/igniter-cluster"')
      end
    end
  end
end
