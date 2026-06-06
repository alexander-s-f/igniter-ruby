# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Igniter::Web::Composer do
  it "composes a screen spec into stable view graph zones" do
    screen = Igniter::Web.screen(:plan_review, intent: :human_decision) do
      title "Plan review"
      subject :project
      show :plan_summary
      show :risk_panel
      compare :current_plan, :proposed_plan
      action :approve, run: "Contracts::ApprovePlan"
      chat with: "Agents::ProjectLead"
      compose with: :decision_workspace
    end

    result = described_class.compose(screen)

    expect(result).to be_success
    expect(result.graph.root.name).to eq(:plan_review)
    expect(result.graph.root.role).to eq(:human_decision)
    expect(result.graph.root.props.fetch(:preset).fetch(:name)).to eq(:decision_workspace)
    expect(result.graph.zone(:summary).children.map(&:kind)).to eq([:subject])
    expect(result.graph.zone(:main).children.map(&:kind)).to eq(%i[show show compare])
    expect(result.graph.zone(:aside).children.map(&:kind)).to eq([:chat])
    expect(result.graph.zone(:footer).children.map(&:kind)).to eq([:action])
  end

  it "returns policy findings when intent has no primary path" do
    screen = Igniter::Web.screen(:approval, intent: :human_decision) do
      show :summary
      compose with: :decision_workspace
    end

    result = described_class.compose(screen)

    expect(result).not_to be_success
    expect(result.findings.map(&:code)).to include(:missing_primary_action)
    expect(result.to_h.fetch(:findings).first.fetch(:suggestions)).to include("add an action")
  end

  it "applies preset-specific zone order and placement hints" do
    screen = Igniter::Web.screen(:brief, intent: :collect_input) do
      title "Brief"
      subject :project
      ask :goal, as: :textarea
      stream :events, from: "Projections::ProjectEvents"
      action :continue, run: "Contracts::DraftPlan"
      compose with: :wizard_operator_surface
    end

    result = described_class.compose(screen)

    expect(result.graph.zones.map(&:name)).to eq(%i[summary main footer aside])
    expect(result.graph.zone(:main).children.map(&:kind)).to eq([:ask])
    expect(result.graph.zone(:footer).children.map(&:kind)).to eq([:action])
    expect(result.graph.zone(:aside).children.map(&:kind)).to eq([:stream])
  end

  it "lets application DSL register composed screens" do
    app = Igniter::Web.application do
      screen :execution, intent: :live_process do
        title "Execution"
        stream :events, from: "Projections::ProjectEvents"
        chat with: "Agents::ProjectLead"
        action :pause, run: "Contracts::PauseProject"
      end
    end

    expect(app.screens.size).to eq(1)
    expect(app.screens.first.graph.zone(:main).children.map(&:kind)).to eq([:stream])
    expect(app.screens.first.graph.zone(:aside).children.map(&:kind)).to eq([:chat])
    expect(app.screens.first.graph.zone(:footer).children.map(&:kind)).to eq([:action])
  end

  it "renders a composed view graph through Arbre" do
    screen = Igniter::Web.screen(:plan_review, intent: :human_decision) do
      title "Plan review"
      subject :project
      show :risk_panel
      compare :current_plan, :proposed_plan
      action :approve, run: "Contracts::ApprovePlan"
      chat with: "Agents::ProjectLead"
      compose with: :decision_workspace
    end
    result = described_class.compose(screen)

    context = instance_double("MountContext", route: "/operator/events")
    html = Igniter::Web.render(result.graph, context: context)

    expect(html).to include("<title>Plan review</title>")
    expect(html).to include("data-ig-screen=\"plan_review\"")
    expect(html).to include("data-ig-preset=\"decision_workspace\"")
    expect(html).to include("data-ig-zone=\"summary\"")
    expect(html).to include("data-ig-node-kind=\"action\"")
    expect(html).to include("class=\"ig-node ig-action ig-action--approve ig-role--primary-action\"")
    expect(html).to include("data-ig-action=\"approve\"")
    expect(html).to include("data-ig-chat-with=\"Agents::ProjectLead\"")
    expect(html).to include("class=\"ig-compare-grid\"")
    expect(html).to include("Contracts::ApprovePlan")
  end

  it "renders ask and stream nodes through specialized components" do
    screen = Igniter::Web.screen(:brief, intent: :collect_input) do
      title "Brief"
      ask :goal, as: :textarea
      stream :events, from: "Projections::ProjectEvents"
      action :continue, run: "Contracts::DraftPlan"
      compose with: :wizard_operator_surface
    end
    result = described_class.compose(screen)

    html = Igniter::Web.render(result.graph)

    expect(html).to include("data-ig-field=\"goal\"")
    expect(html).to include("<textarea")
    expect(html).to include("data-ig-stream=\"events\"")
    expect(html).to include("data-ig-stream-from=\"Projections::ProjectEvents\"")
  end

  it "routes composed screens through the web mount with mount context" do
    web = Igniter::Web.application do
      screen :execution, intent: :live_process do
        title "Execution"
        stream :events, from: "Projections::ProjectEvents"
        chat with: "Agents::ProjectLead"
        action :pause, run: "Contracts::PauseProject"
      end

      screen_route "/execution", :execution
    end
    mount = Igniter::Web.mount(:operator, path: "/operator", application: web)

    status, headers, body = mount.rack_app.call("PATH_INFO" => "/operator/execution")

    expect(status).to eq(200)
    expect(headers.fetch("content-type")).to include("text/html")
    expect(body.join).to include("data-ig-screen=\"execution\"")
    expect(body.join).to include("data-ig-stream=\"events\"")
  end
end
