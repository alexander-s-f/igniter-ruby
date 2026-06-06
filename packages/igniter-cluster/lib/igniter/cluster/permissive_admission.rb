# frozen_string_literal: true

module Igniter
  module Cluster
    class PermissiveAdmission < PolicyAdmission
      def initialize(policy: AdmissionPolicy.permissive)
        super(policy: policy)
      end
    end
  end
end
