# frozen_string_literal: true

module Igniter
  module Cluster
    class DirectPlacement < PolicyPlacement
      def initialize(policy: PlacementPolicy.direct)
        super(policy: policy)
      end
    end
  end
end
