# frozen_string_literal: true

module Igniter
  module Lang
    module Backend
      def compile(...)
        raise NotImplementedError, "#{self.class} must implement #compile"
      end

      def execute(...)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end

      def verify(...)
        raise NotImplementedError, "#{self.class} must implement #verify"
      end
    end
  end
end
