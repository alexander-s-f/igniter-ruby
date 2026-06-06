# frozen_string_literal: true

module Igniter
  module Contracts
    module Assembly
      module Pack
        def install_into(_kernel)
          raise NotImplementedError
        end
      end
    end
  end
end
