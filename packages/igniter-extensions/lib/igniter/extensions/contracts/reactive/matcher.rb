# frozen_string_literal: true

module Igniter
  module Extensions
    module Contracts
      module Reactive
        module Matcher
          module_function

          def match?(subscription, event)
            return false unless subscription.event_type == event.type
            return true if subscription.path.nil?

            subscription.path == event.path
          end
        end
      end
    end
  end
end
