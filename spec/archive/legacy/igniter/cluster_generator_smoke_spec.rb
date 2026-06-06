# frozen_string_literal: true

require "spec_helper"
require "igniter/app/scaffold_pack"
require "json"
require "net/http"
require "open3"
require "timeout"
require "tmpdir"
require "yaml"

RSpec.describe "Cluster scaffold smoke" do
  ROOT = File.expand_path("../..", __dir__)

  def http_get(port, path)
    Net::HTTP.start("127.0.0.1", port, read_timeout: 5) do |http|
      http.get(path)
    end
  end

  def http_post(port, path)
    request = Net::HTTP::Post.new(path)

    Net::HTTP.start("127.0.0.1", port, read_timeout: 5) do |http|
      http.request(request)
    end
  end

  def rewrite_cluster_ports!(root:, base_port:)
    path = File.join(root, "stack.yml")
    data = YAML.load_file(path)
    nodes = data.fetch("nodes")

    seed_port = base_port
    edge_port = base_port + 1
    analyst_port = base_port + 2

    nodes.fetch("seed")["port"] = seed_port
    nodes.fetch("seed").fetch("environment")["MESH_LAB_NODE_URL"] = "http://127.0.0.1:#{seed_port}"

    nodes.fetch("edge")["port"] = edge_port
    nodes.fetch("edge").fetch("environment")["MESH_LAB_NODE_URL"] = "http://127.0.0.1:#{edge_port}"
    nodes.fetch("edge").fetch("environment")["MESH_LAB_SEEDS"] = "http://127.0.0.1:#{seed_port}"

    nodes.fetch("analyst")["port"] = analyst_port
    nodes.fetch("analyst").fetch("environment")["MESH_LAB_NODE_URL"] = "http://127.0.0.1:#{analyst_port}"
    nodes.fetch("analyst").fetch("environment")["MESH_LAB_SEEDS"] = "http://127.0.0.1:#{seed_port}"

    File.write(path, YAML.dump(data))
  end

  it "boots a generated cluster scaffold via bin/dev and serves status, dashboard, and self-heal demo" do
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        Igniter::App::Generators::Cluster.new("mesh_lab").generate
      end

      generated_root = File.join(tmp, "mesh_lab")
      base_port = 46750 + rand(100)
      seed_port = base_port
      rewrite_cluster_ports!(root: generated_root, base_port: base_port)
      output = +""

      Open3.popen2e(
        { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") },
        File.join(generated_root, "bin/dev"),
        chdir: generated_root
      ) do |_stdin, stdout_and_stderr, wait_thread|
        reader = Thread.new do
          stdout_and_stderr.each_line do |line|
            output << line
          end
        end

        begin
          status_response = nil
          dashboard_response = nil
          overview_response = nil
          operator_response = nil
          operator_page_response = nil

          Timeout.timeout(20) do
            loop do
              if wait_thread.join(0)
                raise "generated cluster scaffold exited early:\n#{output}"
              end

              begin
                status_response = http_get(seed_port, "/v1/home/status")
                dashboard_response = http_get(seed_port, "/dashboard")
                overview_response = http_get(seed_port, "/dashboard/api/overview")
                operator_response = http_get(seed_port, "/dashboard/api/operator")
                operator_page_response = http_get(seed_port, "/dashboard/operator")
                break
              rescue Errno::ECONNREFUSED, EOFError, Net::ReadTimeout
                sleep 0.1
              end
            end
          end

          expect(status_response.code).to eq("200")
          expect(status_response["Content-Type"]).to include("application/json")
          status_payload = JSON.parse(status_response.body)
          expect(status_payload.dig("stack", "default_node")).to eq("seed")
          expect(status_payload.dig("current_node", "node", "name")).to eq("mesh_lab-seed")
          expect(status_payload.dig("routing", "active")).to eq(false)

          expect(dashboard_response.code).to eq("200")
          expect(dashboard_response["Content-Type"]).to include("text/html")
          expect(dashboard_response.body).to include("MeshLab Cluster Dashboard")
          expect(dashboard_response.body).to include("Self-Heal Demo")

          expect(overview_response.code).to eq("200")
          expect(overview_response["Content-Type"]).to include("application/json")
          overview_payload = JSON.parse(overview_response.body)
          expect(overview_payload.dig("stack", "default_node")).to eq("seed")
          expect(overview_payload.dig("nodes", "analyst", "port")).to eq(seed_port + 2)

          expect(operator_response.code).to eq("200")
          expect(operator_response["Content-Type"]).to include("application/json")
          operator_payload = JSON.parse(operator_response.body)
          expect(operator_payload["scope"]).to eq("mode" => "app")
          expect(operator_payload["app"]).to eq("MeshLab::DashboardApp")
          expect(operator_payload.dig("summary", "total")).to eq(0)

          expect(operator_page_response.code).to eq("200")
          expect(operator_page_response["Content-Type"]).to include("text/html")
          expect(operator_page_response.body).to include("Operator Console")
          expect(operator_page_response.body).to include("/dashboard/api/operator")

          demo_response = http_post(seed_port, "/dashboard/demo/self-heal?scenario=governance_gate")
          expect(demo_response.code).to eq("303")
          expect(demo_response["Location"]).to eq("/dashboard/?demo=governance_gate")

          healed_overview = JSON.parse(http_get(seed_port, "/dashboard/api/overview").body)
          expect(healed_overview.dig("routing", "active")).to eq(true)
          expect(healed_overview.dig("routing", "plan_count")).to eq(2)
          expect(healed_overview.dig("routing", "incidents", "governance_gate")).to eq(1)

          expect(File.exist?(File.join(generated_root, "var", "log", "dev", "seed.log"))).to be(true)
          expect(output).to include("[stack:dev] writing logs to var/log/dev")
        ensure
          begin
            Process.kill("INT", wait_thread.pid)
          rescue Errno::ESRCH
            nil
          end
          wait_thread.value
          reader.join
        end
      end
    end
  end
end
