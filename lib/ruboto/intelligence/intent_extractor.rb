# frozen_string_literal: true

module Ruboto
  module Intelligence
    module IntentExtractor
      CLASSIFICATION_PROMPT = <<~PROMPT
        You are an email classifier. For each email, determine if it's actionable.
        Return ONLY valid JSON, no other text.

        Supported intents:
        - flight_checkin: airline confirmation emails with flight details
        - hotel_booking: hotel reservation confirmations
        - package_tracking: shipping/delivery notifications with tracking info
        - bill_due: invoices, bills, payment reminders
        - meeting_prep: meeting invitations or agendas needing preparation
        - none: not actionable

        For each actionable email, extract relevant structured data.

        Return format:
        {
          "items": [
            {
              "email_id": "the message id",
              "intent": "one of the intents above",
              "confidence": 0.0 to 1.0,
              "data": { ... extracted fields relevant to the intent ... },
              "action": "human-readable description of what to do",
              "urgency": "immediate|today|upcoming|none"
            }
          ]
        }

        For flight_checkin, extract: airline, confirmation_number, flight_number, date, checkin_url
        For hotel_booking, extract: hotel_name, checkin_date, checkout_date, confirmation_number
        For package_tracking, extract: carrier, tracking_number, tracking_url, delivery_date
        For bill_due, extract: vendor, amount, due_date
        For meeting_prep, extract: title, time, attendees, agenda
      PROMPT

      CONFIDENCE_THRESHOLD = 0.8
      MAX_BATCH_SIZE = 10

      def extract_intents(emails)
        return [] if emails.empty?

        batches = emails.each_slice(MAX_BATCH_SIZE).to_a
        all_intents = []

        batches.each do |batch|
          email_text = batch.map.with_index do |email, i|
            "--- Email #{i + 1} (id: #{email[:id]}) ---\nFrom: #{email[:from]}\nSubject: #{email[:subject]}\nDate: #{email[:date]}\n\n#{email[:body][0, 2000]}"
          end.join("\n\n")

          messages = [
            { role: "system", content: CLASSIFICATION_PROMPT },
            { role: "user", content: "Classify these emails:\n\n#{email_text}" }
          ]

          model = classification_model
          response = call_api(messages, model)

          parsed = parse_classification_response(response)
          all_intents.concat(parsed) if parsed
        end

        all_intents.select { |item| item["intent"] != "none" && item["confidence"].to_f >= CONFIDENCE_THRESHOLD }
      rescue => e
        daemon_log("intent_extraction_error", { error: e.message })
        []
      end

      private

      def classification_model
        cheap = MODELS.find { |m| m[:id].include?("flash") || m[:id].include?("deepseek") }
        (cheap || MODELS.first)[:id]
      end

      def parse_classification_response(response)
        return nil if response["error"]

        content = response.dig("choices", 0, "message", "content")
        return nil unless content

        json_str = content.match(/\{[\s\S]*\}/)&.to_s
        return nil unless json_str

        parsed = JSON.parse(json_str)
        parsed["items"]
      rescue JSON::ParserError
        nil
      end
    end
  end
end
