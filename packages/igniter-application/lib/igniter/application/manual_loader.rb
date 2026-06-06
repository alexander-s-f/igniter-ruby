# frozen_string_literal: true

module Igniter
  module Application
    class ManualLoader
      def load!(base_dir:, paths:, environment:)
        ApplicationLoadReport.inspect(
          base_dir: base_dir,
          layout: environment.layout,
          paths: paths,
          metadata: {
            loader: :manual
          }
        )
      end
    end
  end
end
