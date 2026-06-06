# frozen_string_literal: true

module Igniter
  module Cluster
    class Error < Igniter::Error; end
    class RoutingError < Error; end
    class AdmissionError < Error; end
  end
end
