# frozen_string_literal: true

module Ruboto
  module Workflow
    module PlanGenerator
      TOOL_MAPPING = {
        local_files: "file_glob",
        email: "email_search",
        web: "browser",
        extract: "pdf_extract",
        filter: "data_filter",
        combine: "file_append",
        file: "file_write",
        web_form: "browser",
        email_dest: "email_send"
      }

      def self.generate(parsed_workflow)
        steps = []
        step_id = 0

        # Generate collection steps
        parsed_workflow.sources.each do |source|
          step_id += 1
          steps << build_collection_step(step_id, source)
        end

        # Generate transform steps
        previous_output = steps.last&.output_key
        parsed_workflow.transforms.each do |transform|
          step_id += 1
          steps << build_transform_step(step_id, transform, previous_output)
          previous_output = steps.last.output_key
        end

        # Generate destination steps
        parsed_workflow.destinations.each do |destination|
          step_id += 1
          steps << build_destination_step(step_id, destination, previous_output)
        end

        steps
      end

      def self.build_collection_step(id, source)
        case source[:type]
        when :local_files
          path = expand_path_hint(source[:hint])
          pattern = source[:hint]&.include?("pdf") ? "*.pdf" : "*"
          Step.new(
            id: id,
            tool: "file_glob",
            params: { path: path, pattern: pattern },
            output_key: "collected_files",
            description: "Scan #{path} for #{pattern} files"
          )
        when :email
          Step.new(
            id: id,
            tool: "email_search",
            params: { query: source[:hint] },
            output_key: "collected_emails",
            description: "Search emails matching '#{source[:hint]}'"
          )
        when :web
          Step.new(
            id: id,
            tool: "browser",
            params: { action: "open_url", url: "https://#{source[:hint]}" },
            output_key: "web_page",
            description: "Open #{source[:hint]}"
          )
        else
          Step.new(id: id, tool: "noop", params: {}, description: "Unknown source type")
        end
      end

      def self.build_transform_step(id, transform, input_key)
        case transform[:type]
        when :extract
          Step.new(
            id: id,
            tool: "pdf_extract",
            params: { files: "$#{input_key}", fields: transform[:fields] },
            output_key: "extracted_data",
            description: "Extract #{transform[:fields].join(', ')} from files"
          )
        when :filter
          Step.new(
            id: id,
            tool: "data_filter",
            params: { data: "$#{input_key}", condition: transform[:condition] },
            output_key: "filtered_data",
            description: "Filter data: #{transform[:condition]}"
          )
        when :combine
          Step.new(
            id: id,
            tool: "data_combine",
            params: { data: "$#{input_key}" },
            output_key: "combined_data",
            description: "Combine data"
          )
        else
          Step.new(id: id, tool: "noop", params: {}, description: "Unknown transform")
        end
      end

      def self.build_destination_step(id, destination, input_key)
        case destination[:type]
        when :file
          Step.new(
            id: id,
            tool: "file_append",
            params: { path: expand_path(destination[:path]), data: "$#{input_key}" },
            output_key: nil,
            description: "Append data to #{destination[:path]}"
          )
        when :web_form
          Step.new(
            id: id,
            tool: "browser_form",
            params: { target: destination[:hint], data: "$#{input_key}" },
            output_key: nil,
            description: "Fill #{destination[:hint]} form"
          )
        when :email
          Step.new(
            id: id,
            tool: "email_send",
            params: { to: destination[:hint], data: "$#{input_key}" },
            output_key: nil,
            description: "Email results to #{destination[:hint]}"
          )
        else
          Step.new(id: id, tool: "noop", params: {}, description: "Unknown destination")
        end
      end

      def self.expand_path_hint(hint)
        case hint&.downcase
        when "downloads", "download" then File.expand_path("~/Downloads")
        when "documents", "document" then File.expand_path("~/Documents")
        when "desktop" then File.expand_path("~/Desktop")
        when /^~/ then File.expand_path(hint)
        when /^\// then hint
        else File.expand_path("~/Downloads") # default
        end
      end

      def self.expand_path(path)
        return path if path.nil?
        path.start_with?("~") ? File.expand_path(path) : path
      end
    end
  end
end
