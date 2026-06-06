# frozen_string_literal: true

module Igniter
  module Contracts
    module Execution
      class DiagnosticsReport
        attr_reader :sections

        def initialize
          @sections = {}
        end

        def add_section(name, value)
          section = DiagnosticsSection.new(name: name, value: value)
          sections[section.name] = section
          section
        end

        def section(name)
          value = section_object(name).value
          value.is_a?(NamedValues) ? value.to_h : value
        end

        def section_object(name)
          sections.fetch(name.to_sym)
        end

        def section_names
          sections.keys
        end

        def to_h
          {
            sections: sections.transform_values(&:to_h)
          }
        end
      end
    end
  end
end
