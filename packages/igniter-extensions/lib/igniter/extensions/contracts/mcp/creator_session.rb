# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Mcp
        class CreatorSession
          ATTRIBUTES = %i[
            name
            kind
            namespace
            profile
            capabilities
            scope
            root
            mode
            pack
            target_profile
          ].freeze

          attr_reader(*ATTRIBUTES)

          def initialize(name: nil, kind: nil, namespace: "MyCompany::IgniterPacks", profile: nil, capabilities: nil,
                         scope: nil, root: nil, mode: :skip_existing, pack: nil, target_profile: nil)
            @name = name
            @kind = kind
            @namespace = namespace
            @profile = profile
            @capabilities = capabilities
            @scope = scope
            @root = root
            @mode = mode
            @pack = pack
            @target_profile = target_profile
            freeze
          end

          def self.from_h(payload, target_profile: nil)
            new(
              name: payload[:name] || payload["name"],
              kind: payload[:kind] || payload["kind"],
              namespace: payload[:namespace] || payload["namespace"] || "MyCompany::IgniterPacks",
              profile: payload[:profile] || payload["profile"],
              capabilities: payload[:capabilities] || payload["capabilities"],
              scope: payload[:scope] || payload["scope"],
              root: payload[:root] || payload["root"],
              mode: payload[:mode] || payload["mode"] || :skip_existing,
              pack: payload[:pack] || payload["pack"],
              target_profile: target_profile
            )
          end

          def apply(**updates)
            self.class.new(
              **ATTRIBUTES.to_h { |attribute| [attribute, updates.fetch(attribute, public_send(attribute))] }
            )
          end

          def wizard
            CreatorPack.wizard(
              name: name,
              kind: kind,
              namespace: namespace,
              profile: profile,
              capabilities: capabilities,
              scope: scope,
              root: root,
              mode: mode,
              pack: pack,
              target_profile: target_profile
            )
          end

          def workflow_payload
            wizard.workflow.to_h
          end

          def write_plan_payload
            wizard.writer.plan.to_h
          end

          def write_payload
            wizard.writer.write.to_h
          end

          def to_h
            wizard.to_h.merge(
              session: {
                name: name,
                kind: kind,
                namespace: namespace,
                profile: profile,
                capabilities: Array(capabilities).map(&:to_sym),
                scope: scope,
                root: root,
                mode: mode,
                target_profile_fingerprint: target_profile&.fingerprint
              }
            )
          end
        end
      end
    end
  end
end
