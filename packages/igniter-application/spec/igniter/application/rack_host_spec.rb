# frozen_string_literal: true

require "stringio"
require "tmpdir"

require_relative "../../spec_helper"

RSpec.describe Igniter::Application::RackHost do
  class RackHostCounter
    attr_reader :value

    def initialize
      @value = 0
    end

    def increment(id)
      @value += Integer(id)
    end
  end

  class RackHostMount
    attr_reader :environment

    def bind(environment:)
      self.class.new(environment: environment)
    end

    def initialize(environment: nil)
      @environment = environment
    end

    def rack_app
      lambda do |_env|
        counter = environment.service(:counter).call
        [200, { "content-type" => "text/plain; charset=utf-8" }, ["counter=#{counter.value}"]]
      end
    end
  end

  def rack_env(method, path, body = "")
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body)
    }
  end

  it "builds an inspectable Rack app over services, web mounts, and explicit routes" do
    Dir.mktmpdir("igniter-rack-host") do |root|
      app = Igniter::Application.rack_app(:counter_app, root: root, env: :test) do
        service(:counter) { RackHostCounter.new }

        mount_web(
          :counter_screen,
          RackHostMount.new,
          at: "/",
          capabilities: %i[screen command],
          metadata: { test: true }
        )

        get "/events" do
          text "value=#{service(:counter).value}"
        end

        post "/counter" do |params|
          service(:counter).increment(params.fetch("id"))
          redirect "/"
        end
      end

      initial_status, _initial_headers, initial_body = app.call(rack_env("GET", "/"))
      post_status, post_headers, _post_body = app.call(rack_env("POST", "/counter", "id=2"))
      final_status, _final_headers, final_body = app.call(rack_env("GET", "/"))
      events_status, _events_headers, events_body = app.call(rack_env("GET", "/events"))
      missing_status, _missing_headers, missing_body = app.call(rack_env("GET", "/missing"))

      expect(initial_status).to eq(200)
      expect(initial_body.join).to eq("counter=0")
      expect(post_status).to eq(303)
      expect(post_headers).to include("location" => "/")
      expect(final_status).to eq(200)
      expect(final_body.join).to eq("counter=2")
      expect(events_status).to eq(200)
      expect(events_body.join).to eq("value=2")
      expect(missing_status).to eq(404)
      expect(missing_body.join).to eq("not found")
      expect(app.service(:counter).value).to eq(2)
      expect(app.environment.manifest.to_h).to include(name: :counter_app, root: root, env: :test)
      expect(app.to_h).to include(
        name: :counter_app,
        root: root,
        env: :test,
        services: [:counter],
        routes: include({ method: "GET", path: "/events" }, { method: "POST", path: "/counter" }),
        web_mounts: [
          {
            name: :counter_screen,
            at: "/",
            capabilities: %i[screen command],
            metadata: { test: true }
          }
        ]
      )
    end
  end

  it "merges dynamic route params into request params" do
    Dir.mktmpdir("igniter-rack-host") do |root|
      app = Igniter::Application.rack_app(:dynamic_app, root: root, env: :test) do
        post "/sessions/:id/steps" do |params|
          text "session=#{params.fetch("id")} action=#{params.fetch("action")}"
        end
      end

      status, _headers, body = app.call(rack_env("POST", "/sessions/session-123/steps", "action=done"))

      expect(status).to eq(200)
      expect(body.join).to eq("session=session-123 action=done")
    end
  end
end
