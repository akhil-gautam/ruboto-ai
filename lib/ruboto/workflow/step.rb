# frozen_string_literal: true

module Ruboto
  module Workflow
    class Step
      attr_accessor :id, :tool, :params, :output_key, :description, :confidence, :status

      def initialize(id:, tool:, params: {}, output_key: nil, description: nil)
        @id = id
        @tool = tool
        @params = params
        @output_key = output_key
        @description = description || "#{tool} step"
        @confidence = 0.0
        @status = :pending
      end

      def to_h
        {
          id: @id,
          tool: @tool,
          params: @params,
          output_key: @output_key,
          description: @description,
          confidence: @confidence,
          status: @status
        }
      end

      def self.from_h(hash)
        step = new(
          id: hash[:id] || hash["id"],
          tool: hash[:tool] || hash["tool"],
          params: hash[:params] || hash["params"] || {},
          output_key: hash[:output_key] || hash["output_key"],
          description: hash[:description] || hash["description"]
        )
        step.confidence = hash[:confidence] || hash["confidence"] || 0.0
        step.status = (hash[:status] || hash["status"] || :pending).to_sym
        step
      end
    end
  end
end
