# frozen_string_literal: true

module Ruboto
  module Workflow
    class Runtime
      # Will be implemented in Task 3
      def initialize(steps, mode: :supervised)
        @steps = steps
        @mode = mode
      end
    end
  end
end
