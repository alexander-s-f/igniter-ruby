# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Dataflow
        Diff = Struct.new(:added, :removed, :changed, :unchanged, keyword_init: true) do
          def any_changes?
            added.any? || removed.any? || changed.any?
          end

          def processed_count
            added.size + changed.size
          end

          def explain
            parts = []
            parts << "added(#{added.size}): #{added.inspect}" unless added.empty?
            parts << "removed(#{removed.size}): #{removed.inspect}" unless removed.empty?
            parts << "changed(#{changed.size}): #{changed.inspect}" unless changed.empty?
            parts << "unchanged(#{unchanged.size})" unless unchanged.empty?
            parts.empty? ? "(no changes)" : parts.join(", ")
          end

          def to_h
            {
              added: added,
              removed: removed,
              changed: changed,
              unchanged: unchanged
            }
          end
        end
      end
    end
  end
end
