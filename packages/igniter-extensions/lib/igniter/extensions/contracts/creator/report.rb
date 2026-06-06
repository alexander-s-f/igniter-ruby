# frozen_string_literal: true

require_relative "scaffold"

module Igniter
  module Extensions
    module Contracts
      module Creator
        class Report
          attr_reader :scaffold, :audit

          def initialize(scaffold:, audit: nil)
            @scaffold = scaffold
            @audit = audit
            freeze
          end

          def next_steps
            steps = [
              "fill in #{scaffold.pack_file_path} using only public Igniter::Contracts APIs",
              "run the generated spec and example",
              "use Igniter::Extensions::Contracts.audit_pack(...) before finalize"
            ]

            case scaffold.profile.name
            when :feature_node
              steps << "implement node kind, DSL keyword, validator, and runtime handler"
            when :operational_adapter
              steps << "implement effect and executor handlers with typed invocation contracts"
            when :diagnostic_bundle
              steps << "compose the suggested diagnostic dependency packs and add one pack-specific diagnostics contributor"
            when :bundle_pack
              steps << "install dependency packs and keep the bundle free of hidden runtime mutation"
            else
              case scaffold.kind
              when :feature
                steps << "make sure declared node contracts, DSL, validators, and runtime handlers stay aligned"
              when :operational
                steps << "make sure executor/effect contracts stay aligned with typed invocation objects"
              when :bundle
                steps << "prefer explicit dependency installation over hidden runtime mutation"
              end
            end

            steps << "review dependency hints: #{scaffold.profile.dependency_hints.join(", ")}" unless scaffold.profile.dependency_hints.empty?

            scaffold.profile.development_hints.each do |hint|
              steps << hint
            end

            scaffold.scope.packaging_hints.each do |hint|
              steps << hint
            end

            steps
          end

          def quality_bar
            {
              public_contracts_only: true,
              includes_spec: true,
              includes_example: true,
              includes_readme: true,
              audit_ok: audit&.ok?,
              authoring_profile: scaffold.profile.name,
              target_scope: scaffold.scope.name,
              runtime_dependency_hints: scaffold.profile.runtime_dependency_hints,
              development_dependency_hints: scaffold.profile.development_dependency_hints
            }
          end

          def to_h
            payload = {
              scaffold: scaffold.to_h,
              next_steps: next_steps,
              quality_bar: quality_bar
            }
            payload[:audit] = audit.to_h if audit
            payload
          end
        end
      end
    end
  end
end
