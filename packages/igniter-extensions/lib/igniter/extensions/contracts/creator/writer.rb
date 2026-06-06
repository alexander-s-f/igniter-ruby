# frozen_string_literal: true

require "fileutils"

require_relative "write_step"
require_relative "write_result"

module Igniter
  module Extensions
    module Contracts
      module Creator
        class Writer
          VALID_MODES = %i[skip_existing overwrite].freeze

          attr_reader :workflow, :root, :mode

          def initialize(workflow:, root:, mode: :skip_existing)
            @workflow = workflow
            @root = File.expand_path(root.to_s)
            @mode = normalize_mode(mode)
            freeze
          end

          def scaffold
            workflow.scaffold
          end

          def plan
            WriteResult.new(root: root, mode: mode, steps: plan_steps)
          end

          def write
            WriteResult.new(root: root, mode: mode, steps: directory_steps + file_steps)
          end

          private

          def normalize_mode(mode)
            value = mode.to_sym
            return value if VALID_MODES.include?(value)

            raise ArgumentError, "unsupported creator writer mode #{mode.inspect}"
          end

          def plan_steps
            planned_directories + planned_files
          end

          def planned_directories
            directories.map do |relative_path|
              WriteStep.new(
                kind: :directory,
                relative_path: relative_path,
                absolute_path: absolute_path_for(relative_path),
                status: File.directory?(absolute_path_for(relative_path)) ? :unchanged : :pending
              )
            end
          end

          def planned_files
            scaffold.files.map do |relative_path, _content|
              absolute_path = absolute_path_for(relative_path)
              WriteStep.new(
                kind: :file,
                relative_path: relative_path,
                absolute_path: absolute_path,
                status: file_plan_status(absolute_path)
              )
            end
          end

          def directory_steps
            directories.map do |relative_path|
              absolute_path = absolute_path_for(relative_path)
              existed = File.directory?(absolute_path)
              FileUtils.mkdir_p(absolute_path)
              WriteStep.new(
                kind: :directory,
                relative_path: relative_path,
                absolute_path: absolute_path,
                status: existed ? :unchanged : :created
              )
            end
          end

          def file_steps
            scaffold.files.map do |relative_path, content|
              absolute_path = absolute_path_for(relative_path)
              parent = File.dirname(absolute_path)
              FileUtils.mkdir_p(parent)

              if File.exist?(absolute_path) && mode == :skip_existing
                WriteStep.new(
                  kind: :file,
                  relative_path: relative_path,
                  absolute_path: absolute_path,
                  status: :skipped,
                  reason: "existing file preserved"
                )
              else
                status = File.exist?(absolute_path) && File.read(absolute_path) == content ? :unchanged : :written
                File.write(absolute_path, content)
                WriteStep.new(
                  kind: :file,
                  relative_path: relative_path,
                  absolute_path: absolute_path,
                  status: status
                )
              end
            end
          end

          def file_plan_status(absolute_path)
            return :pending unless File.exist?(absolute_path)
            return :skipped if mode == :skip_existing

            :pending
          end

          def directories
            scaffold.files.keys.map { |path| File.dirname(path) }.uniq.sort
          end

          def absolute_path_for(relative_path)
            File.join(root, relative_path)
          end
        end
      end
    end
  end
end
