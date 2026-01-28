# frozen_string_literal: true

module Ruboto
  module Workflow
    module IntentParser
      ParsedWorkflow = Struct.new(:name, :trigger, :sources, :transforms, :destinations, :raw_description, keyword_init: true)

      TRIGGER_PATTERNS = {
        schedule: /every\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|day|week|month|morning|evening|\d+\s*(am|pm|hours?|minutes?))/i,
        file_watch: /(when|whenever)\s+(a\s+)?(new\s+)?file/i,
        email_match: /(when|whenever)\s+(i\s+)?(get|receive)\s+(an?\s+)?email/i,
        manual: nil
      }

      def self.parse(description)
        trigger = detect_trigger(description)
        sources = detect_sources(description)
        transforms = detect_transforms(description)
        destinations = detect_destinations(description)

        ParsedWorkflow.new(
          name: generate_name(description),
          trigger: trigger,
          sources: sources,
          transforms: transforms,
          destinations: destinations,
          raw_description: description
        )
      end

      def self.detect_trigger(description)
        TRIGGER_PATTERNS.each do |type, pattern|
          next unless pattern
          return { type: type, match: description.match(pattern)&.to_s } if description.match?(pattern)
        end
        { type: :manual, match: nil }
      end

      def self.detect_sources(description)
        sources = []
        sources << { type: :local_files, hint: $1 } if description =~ /(downloads?|documents?|desktop)\s+folder/i
        sources << { type: :local_files, hint: $1 } if description =~ /from\s+(?:the\s+)?([~\/][\w\/.-]+)/
        sources << { type: :local_files, hint: "pdf" } if description =~ /pdf|invoice|receipt/i
        sources << { type: :email, hint: $1 } if description =~ /email.*from\s+(\S+)/i
        sources << { type: :web, hint: $1 } if description =~ /(?:from|on|in)\s+([\w.-]+\.com)/i
        sources
      end

      def self.detect_transforms(description)
        transforms = []
        transforms << { type: :extract, fields: $1.split(/[,\s]+and\s+|,\s*/) } if description =~ /extract\s+(.+?)\s+from/i
        transforms << { type: :filter, condition: $1 } if description =~ /filter\s+(.+)/i
        transforms << { type: :combine, target: $1 } if description =~ /(?:add|append|combine).+?(?:to|into)\s+(\S+)/i
        transforms
      end

      def self.detect_destinations(description)
        destinations = []
        destinations << { type: :file, path: $1 } if description =~ /(?:add|append|save|write).+?(?:to|into)\s+([~\/]?[\w\/.-]+\.\w+)/i
        destinations << { type: :file, path: $1 } if description =~ /(\S+\.csv|\S+\.xlsx)/i
        destinations << { type: :web_form, hint: $1 } if description =~ /fill\s+(?:out\s+)?(?:the\s+)?(\S+)\s+form/i
        destinations << { type: :web_form, hint: $1 } if description =~ /(?:on|in)\s+(workday|salesforce|quickbooks)/i
        destinations << { type: :email, hint: $1 } if description =~ /email\s+(?:it\s+)?to\s+(\S+)/i
        destinations
      end

      def self.generate_name(description)
        words = description.downcase.gsub(/[^\w\s]/, '').split
        stop_words = %w[the a an to from in on at by for with every when i my]
        key_words = words.reject { |w| stop_words.include?(w) || w.length < 3 }
        key_words.first(4).join("-")
      end
    end
  end
end
