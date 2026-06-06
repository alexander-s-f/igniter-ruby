# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Creator
        class Scaffold
          SUPPORTED_KINDS = %i[feature operational bundle].freeze

          attr_reader :name, :kind, :namespace, :profile, :scope

          def initialize(name:, kind:, namespace:, profile:, scope:)
            @name = normalize_name(name)
            @kind = normalize_kind(kind)
            @namespace = normalize_namespace(namespace)
            @profile = profile
            @scope = scope
            freeze
          end

          def pack_class_name
            "#{camelize(name)}Pack"
          end

          def pack_constant
            "#{namespace}::#{pack_class_name}"
          end

          def namespace_path
            namespace.split("::").map { |part| underscore(part) }.join("/")
          end

          def pack_file_path
            "#{scope.root}/#{namespace_path}/#{name}_pack.rb"
          end

          def spec_file_path
            "#{scope.spec_root}/#{namespace_path}/#{name}_pack_spec.rb"
          end

          def example_file_path
            "#{scope.example_root}/#{name}_pack.rb"
          end

          def readme_file_path
            scope.readme_path
          end

          def files
            {
              pack_file_path => pack_template,
              spec_file_path => spec_template,
              example_file_path => example_template,
              readme_file_path => readme_template
            }
          end

          def summary
            {
              name: name,
              kind: kind,
              namespace: namespace,
              profile: profile.to_h,
              scope: scope.to_h,
              pack_constant: pack_constant,
              files: files.keys
            }
          end

          def to_h
            summary.merge(files: files)
          end

          private

          def normalize_name(name)
            name.to_s.strip.gsub(/_pack\z/, "").downcase
          end

          def normalize_kind(kind)
            value = kind.to_sym
            return value if SUPPORTED_KINDS.include?(value)

            raise ArgumentError, "unsupported creator scaffold kind #{kind.inspect}"
          end

          def normalize_namespace(namespace)
            value = namespace.to_s.strip
            return value unless value.empty?

            "MyCompany::IgniterPacks"
          end

          def camelize(value)
            value.split("_").map(&:capitalize).join
          end

          def underscore(value)
            value.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
          end

          def pack_template
            case kind
            when :feature then feature_pack_template
            when :operational then operational_pack_template
            when :bundle then bundle_pack_template
            end
          end

          def spec_template
            case kind
            when :feature then feature_spec_template
            when :operational then operational_spec_template
            when :bundle then bundle_spec_template
            end
          end

          def example_template
            case kind
            when :feature then feature_example_template
            when :operational then operational_example_template
            when :bundle then bundle_example_template
            end
          end

          def readme_template
            <<~MARKDOWN
              # #{pack_class_name}

              #{pack_class_name} is a #{kind} pack built on top of `igniter-contracts`.

              ## Files

              - `#{pack_file_path}` — pack implementation
              - `#{spec_file_path}` — package-owned spec
              - `#{example_file_path}` — runnable example

              ## Authoring Profile

              - `#{profile.name}`
              - capabilities: `#{profile.capabilities.join("`, `")}`
              - registry seams: `#{profile.registry_capabilities.join("`, `")}`
              #{runtime_dependency_hints_markdown}
              #{development_dependency_hints_markdown}
              #{development_hints_markdown}

              ## Target Scope

              - `#{scope.name}`
              - pack root: `#{scope.root}`
              - spec root: `#{scope.spec_root}`
              - example root: `#{scope.example_root}`
              #{packaging_hints_markdown}

              ## Recommended Workflow

              1. Fill in the pack implementation using only public `Igniter::Contracts` APIs.
              2. Run the generated spec and example.
              3. Use `Igniter::Extensions::Contracts.audit_pack(#{pack_constant}, environment)` to verify completeness.
              4. Only then decide whether the pack remains app-local or becomes a distributable gem.
            MARKDOWN
          end

          def feature_pack_template
            <<~RUBY
              # frozen_string_literal: true

              module #{namespace}
                module #{pack_class_name}
                  class << self
                    def manifest
                      Igniter::Contracts::PackManifest.new(#{feature_manifest_body})
                    end

                    def install_into(kernel)
                      kernel.nodes.register(:#{name}, Igniter::Contracts::NodeType.new(kind: :#{name}, metadata: { category: :custom }))
                      kernel.dsl_keywords.register(:#{name}, #{name}_keyword)
                      kernel.validators.register(:#{name}_sources, method(:validate_#{name}_sources))
                      kernel.runtime_handlers.register(:#{name}, method(:handle_#{name}))
                      kernel
                    end

                    def #{name}_keyword
                      Igniter::Contracts::DslKeyword.new(:#{name}) do |name, from:, builder:|
                        builder.add_operation(kind: :#{name}, name: name, from: from.to_sym)
                      end
                    end

                    def validate_#{name}_sources(operations:, profile: nil) # rubocop:disable Lint/UnusedMethodArgument
                      []
                    end

                    def handle_#{name}(operation:, state:, **)
                      state.fetch(operation.attributes.fetch(:from).to_sym)
                    end
                  end
                end
              end
            RUBY
          end

          def operational_pack_template
            <<~RUBY
              # frozen_string_literal: true

              module #{namespace}
                module #{pack_class_name}
                  class << self
                    def manifest
                      Igniter::Contracts::PackManifest.new(#{operational_manifest_body})
                    end

                    def install_into(kernel)
                      kernel.effects.register(:#{name}, method(:apply_#{name}))
                      kernel.executors.register(:#{name}_inline, method(:execute_#{name}_inline))
                      kernel
                    end

                    def apply_#{name}(invocation:)
                      invocation.payload
                    end

                    def execute_#{name}_inline(invocation:)
                      invocation.runtime.execute(
                        invocation.compiled_graph,
                        inputs: invocation.inputs,
                        profile: invocation.profile
                      )
                    end
                  end
                end
              end
            RUBY
          end

          def bundle_pack_template
            <<~RUBY
              # frozen_string_literal: true

              module #{namespace}
                module #{pack_class_name}
                  class << self
                    def manifest
                      Igniter::Contracts::PackManifest.new(
                        name: :#{name},
                        #{bundle_manifest_body}
                      )
                    end

                    def install_into(kernel)
                      #{bundle_diagnostic_install_lines}
                      kernel
                    end

                    #{bundle_diagnostic_contributor_template}
                  end
                end
              end
            RUBY
          end

          def feature_spec_template
            <<~RUBY
              # frozen_string_literal: true

              RSpec.describe #{pack_constant} do
                it "installs a feature node pack through public contracts APIs" do
                  environment = Igniter::Contracts.with(described_class)

                  result = environment.run(inputs: { source: "value" }) do
                    input :source
                    #{name} :result, from: :source
                    output :result
                  end

                  expect(result.output(:result)).to eq("value")
                end
              end
            RUBY
          end

          def operational_spec_template
            <<~RUBY
              # frozen_string_literal: true

              RSpec.describe #{pack_constant} do
                it "installs effect and executor seams through public contracts APIs" do
                  environment = Igniter::Contracts.with(described_class)

                  compiled = environment.compile do
                    input :amount
                    output :amount
                  end

                  result = environment.execute_with(:#{name}_inline, compiled, inputs: { amount: 10 })

                  expect(environment.apply_effect(:#{name}, payload: { amount: 10 })).to eq(amount: 10)
                  expect(result.output(:amount)).to eq(10)
                end
              end
            RUBY
          end

          def bundle_spec_template
            <<~RUBY
              # frozen_string_literal: true

              RSpec.describe #{pack_constant} do
                it "installs a bundle pack without depending on contracts internals" do
                  profile = Igniter::Contracts.build_profile(described_class)

                  expect(profile.pack_names).to include(:#{name})
                end
              end
            RUBY
          end

          def feature_example_template
            <<~RUBY
              # frozen_string_literal: true

              require "igniter/contracts"

              environment = Igniter::Contracts.with(#{pack_constant})

              result = environment.run(inputs: { source: "hello" }) do
                input :source
                #{name} :result, from: :source
                output :result
              end

              audit = Igniter::Extensions::Contracts.audit_pack(#{pack_constant}, environment)

              puts "creator_example_output=\#{result.output(:result)}"
              puts "creator_example_audit_ok=\#{audit.ok?}"
            RUBY
          end

          def operational_example_template
            <<~RUBY
              # frozen_string_literal: true

              require "igniter/contracts"

              environment = Igniter::Contracts.with(#{pack_constant})

              compiled = environment.compile do
                input :amount
                output :amount
              end

              effect_result = environment.apply_effect(:#{name}, payload: { amount: 10 })
              execution_result = environment.execute_with(:#{name}_inline, compiled, inputs: { amount: 15 })

              puts "creator_effect_payload=\#{effect_result.inspect}"
              puts "creator_execution_output=\#{execution_result.output(:amount)}"
            RUBY
          end

          def bundle_example_template
            <<~RUBY
              # frozen_string_literal: true

              require "igniter/contracts"

              profile = Igniter::Contracts.build_profile(#{pack_constant})

              puts "creator_bundle_profile=\#{profile.pack_names.join(',')}"
            RUBY
          end

          def runtime_dependency_hints_markdown
            return "" if profile.runtime_dependency_hints.empty?

            "              - runtime dependency packs: `#{profile.runtime_dependency_hints.join("`, `")}`"
          end

          def development_dependency_hints_markdown
            return "" if profile.development_dependency_hints.empty?

            "              - development tool packs: `#{profile.development_dependency_hints.join("`, `")}`"
          end

          def development_hints_markdown
            return "" if profile.development_hints.empty?

            "              - development hints: `#{profile.development_hints.join("`; `")}`"
          end

          def packaging_hints_markdown
            return "" if scope.packaging_hints.empty?

            "              - packaging hints: `#{scope.packaging_hints.join("`; `")}`"
          end

          def bundle_manifest_body
            lines = ["metadata: { category: :bundle }"]
            append_runtime_dependency_manifest_line(lines)
            lines << "registry_contracts: [Igniter::Contracts::PackManifest.diagnostic(:#{name}_summary)]" if profile.capability?(:diagnostic)
            lines.join(",\n                        ")
          end

          def feature_manifest_body
            lines = [
              "name: :#{name}",
              "node_contracts: [Igniter::Contracts::PackManifest.node(:#{name})]",
              "registry_contracts: [Igniter::Contracts::PackManifest.validator(:#{name}_sources)]"
            ]
            append_runtime_dependency_manifest_line(lines)
            lines.join(",\n                        ")
          end

          def operational_manifest_body
            lines = [
              "name: :#{name}",
              <<~RUBY.chomp
                registry_contracts: [
                          Igniter::Contracts::PackManifest.effect(:#{name}),
                          Igniter::Contracts::PackManifest.executor(:#{name}_inline)
                        ]
              RUBY
            ]
            append_runtime_dependency_manifest_line(lines)
            lines.join(",\n                        ")
          end

          def append_runtime_dependency_manifest_line(lines)
            return lines if profile.runtime_dependency_hints.empty?

            lines << "requires_packs: [#{profile.runtime_dependency_hints.join(", ")}]"
          end

          def bundle_diagnostic_install_lines
            return "# no diagnostics contributor for this profile" unless profile.capability?(:diagnostic)

            "kernel.diagnostics_contributors.register(:#{name}_summary, #{name}_summary)"
          end

          def bundle_diagnostic_contributor_template
            return "" unless profile.capability?(:diagnostic)

            <<~RUBY.chomp
              def #{name}_summary
                Module.new do
                  module_function

                  def augment(report:, result:, profile:) # rubocop:disable Lint/UnusedMethodArgument
                    report.add_section(:#{name}_summary, {
                      output_names: result.outputs.keys.sort,
                      pack_names: profile.pack_names.sort
                    })
                  end
                end
              end
            RUBY
          end
        end
      end
    end
  end
end
