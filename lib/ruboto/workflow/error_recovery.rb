# frozen_string_literal: true

module Ruboto
  module Workflow
    class ErrorRecovery
      attr_reader :last_error, :attempts

      DEFAULT_MAX_RETRIES = 3
      DEFAULT_BASE_DELAY = 1.0  # seconds
      MAX_DELAY = 30.0  # seconds

      # Error severity classifications
      RETRYABLE_ERRORS = [
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH,
        Timeout::Error,
        IOError
      ].freeze

      NON_CRITICAL_ERRORS = [
        Errno::ENOENT,      # File not found
        Errno::EACCES,      # Permission denied
        ArgumentError
      ].freeze

      def initialize(max_retries: DEFAULT_MAX_RETRIES, backoff: :exponential, base_delay: DEFAULT_BASE_DELAY)
        @max_retries = max_retries
        @backoff = backoff
        @base_delay = base_delay
        @last_error = nil
        @attempts = 0
      end

      # Execute block with retry logic
      def with_retry
        @attempts = 0
        @last_error = nil

        loop do
          @attempts += 1

          begin
            return yield
          rescue => e
            @last_error = e
            severity = classify_error(e)

            # Don't retry critical errors
            break if severity == :critical

            # Check if we've exceeded max retries
            break if @attempts >= @max_retries

            # Wait before retry (unless it's the last attempt)
            delay = calculate_delay(@attempts)
            sleep(delay) if delay > 0
          end
        end

        nil  # Return nil on failure
      end

      # Classify error severity
      def classify_error(error)
        error_class = error.class

        # Check if it's a retryable error
        RETRYABLE_ERRORS.each do |err_class|
          return :retryable if error_class <= err_class
        end

        # Check if it's non-critical
        NON_CRITICAL_ERRORS.each do |err_class|
          return :non_critical if error_class <= err_class
        end

        # Default to critical for unknown errors
        :critical
      end

      # Get human-readable error description
      def describe_error(error)
        case classify_error(error)
        when :retryable
          "Temporary error (will retry): #{error.message}"
        when :non_critical
          "Non-critical error (continuing): #{error.message}"
        when :critical
          "Critical error: #{error.message}"
        end
      end

      # Create a recovery strategy for a step
      def self.for_step(step, options = {})
        # Customize retry behavior based on step tool
        case step.tool
        when "browser", "browser_form"
          # Browser steps might need more retries for page loads
          new(max_retries: 4, backoff: :exponential, base_delay: 2.0)
        when "email_send"
          # Email sending should retry on network issues
          new(max_retries: 3, backoff: :exponential, base_delay: 5.0)
        when "file_glob", "csv_read", "pdf_extract"
          # File operations usually succeed or fail immediately
          new(max_retries: 2, backoff: :linear, base_delay: 1.0)
        else
          new(**options)
        end
      end

      # Execute a step with recovery
      def self.execute_with_recovery(step, params, &executor)
        recovery = for_step(step)

        result = recovery.with_retry do
          executor.call(step, params)
        end

        if result.nil? && recovery.last_error
          {
            success: false,
            error: recovery.describe_error(recovery.last_error),
            attempts: recovery.attempts,
            recoverable: recovery.classify_error(recovery.last_error) != :critical
          }
        else
          result
        end
      end

      private

      def calculate_delay(attempt)
        case @backoff
        when :exponential
          delay = @base_delay * (2 ** (attempt - 1))
          [delay, MAX_DELAY].min
        when :linear
          delay = @base_delay * attempt
          [delay, MAX_DELAY].min
        when :constant
          @base_delay
        else
          0
        end
      end
    end
  end
end
