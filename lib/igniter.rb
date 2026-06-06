# frozen_string_literal: true

require_relative "igniter/monorepo_packages"
require_relative "igniter/version"
require "igniter/contracts"
require "igniter/embed"
require "igniter/application"
require "igniter/ai"
require "igniter/agents"
require "igniter/hub"

module Igniter
  class << self
    def build_kernel(*packs)
      Contracts.build_kernel(*packs)
    end

    def build_profile(*packs)
      Contracts.build_profile(*packs)
    end

    def with(*packs)
      Contracts.with(*packs)
    end

    def compile(...)
      Contracts.compile(...)
    end

    def validation_report(...)
      Contracts.validation_report(...)
    end

    def compilation_report(...)
      Contracts.compilation_report(...)
    end

    def execute(...)
      Contracts.execute(...)
    end

    def embed(...)
      Embed.configure(...)
    end

    def execute_with(...)
      Contracts.execute_with(...)
    end

    def diagnose(...)
      Contracts.diagnose(...)
    end

    def apply_effect(...)
      Contracts.apply_effect(...)
    end

    def build_application_kernel(*packs)
      Application.build_kernel(*packs)
    end

    def build_application_profile(*packs)
      Application.build_profile(*packs)
    end

    def application(*packs)
      Application.with(*packs)
    end

    def ai_client(...)
      AI.client(...)
    end

    def agent(...)
      Agents.agent(...)
    end

    def hub_catalog(...)
      Hub.local_catalog(...)
    end
  end
end
