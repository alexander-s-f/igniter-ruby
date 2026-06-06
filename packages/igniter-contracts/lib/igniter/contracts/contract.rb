# frozen_string_literal: true

module Igniter
  class Contract
    class ResultReader
      def initialize(outputs)
        @outputs = outputs
        freeze
      end

      def output(name)
        @outputs.fetch(name.to_sym)
      rescue KeyError
        raise KeyError, "unknown contract output #{name}"
      end

      def to_h
        @outputs.to_h
      end

      def method_missing(name, *args, &block)
        return output(name) if args.empty? && block.nil? && @outputs.key?(name)
        raise KeyError, "unknown contract output #{name}" if args.empty? && block.nil?

        super
      end

      def respond_to_missing?(name, include_private = false)
        @outputs.key?(name) || super
      end
    end

    class << self
      attr_writer :profile

      def inherited(subclass)
        super
        subclass.profile = profile
      end

      def define(&block)
        raise ArgumentError, "contract definition requires a block" unless block

        @definition_block = block
        @compiled_graphs = {}
        self
      end

      def definition_block
        @definition_block || raise(Contracts::Error, "#{name || self} does not define a contract")
      end

      def profile
        @profile || Contracts.default_profile
      end

      def compile(profile: self.profile)
        compiled_graphs.fetch(profile.fingerprint) do
          compiled_graphs[profile.fingerprint] = Contracts.compile(profile: profile, &definition_block)
        end
      end

      def call(inputs = nil, profile: self.profile, **keyword_inputs)
        new(inputs, profile: profile, **keyword_inputs)
      end

      def execute(inputs = nil, profile: self.profile, **keyword_inputs)
        contract = new(inputs, profile: profile, **keyword_inputs)
        contract.execution_result
      end

      private

      def compiled_graphs
        @compiled_graphs ||= {}
      end
    end

    attr_reader :inputs, :profile, :execution_result

    def initialize(inputs = nil, profile: self.class.profile, **keyword_inputs)
      @profile = profile
      @inputs = normalize_inputs(inputs, keyword_inputs)
      run!
    end

    def result
      ResultReader.new(execution_result.outputs)
    end

    def outputs
      execution_result.outputs
    end

    def output(name)
      result.output(name)
    end

    def success?
      true
    end

    def failure?
      !success?
    end

    def update_inputs(inputs = nil, **keyword_inputs)
      @inputs = @inputs.merge(normalize_inputs(inputs, keyword_inputs))
      run!
      self
    end

    def to_h
      {
        contract: self.class.name,
        inputs: inputs.dup,
        outputs: outputs.to_h,
        success: success?
      }
    end

    private

    def run!
      @execution_result = Contracts.execute(self.class.compile(profile: profile), inputs: inputs, profile: profile)
    end

    def normalize_inputs(inputs, keyword_inputs)
      normalized_inputs = {}
      normalized_inputs.merge!(inputs) if inputs
      normalized_inputs.merge!(keyword_inputs)
      normalized_inputs.transform_keys(&:to_sym)
    end
  end
end
