# frozen_string_literal: true

require "json"

module Ruboto
  module Workflow
    module ExportImport
      extend self

      EXPORT_VERSION = "1.0"

      # Export a workflow to a hash
      def export_workflow(workflow_id)
        workflow = Storage.load_workflow(workflow_id)
        return nil unless workflow

        steps = Storage.load_steps(workflow_id)

        # Get trigger history for context
        trigger_manager = TriggerManager.new
        trigger_history = trigger_manager.get_trigger_history(workflow_id, 5)

        # Get correction patterns
        corrections = []
        steps.each do |step|
          tracker = ConfidenceTracker.new(workflow_id: workflow_id, step_order: step[:step_order])
          step_corrections = tracker.get_corrections
          corrections.concat(step_corrections) if step_corrections.any?
        end

        {
          export_version: EXPORT_VERSION,
          exported_at: Time.now.iso8601,
          name: workflow[:name],
          description: workflow[:description],
          trigger_type: workflow[:trigger_type],
          trigger_config: workflow[:trigger_config],
          sources: workflow[:sources],
          transforms: workflow[:transforms],
          destinations: workflow[:destinations],
          overall_confidence: workflow[:overall_confidence],
          run_count: workflow[:run_count],
          success_count: workflow[:success_count],
          steps: steps.map do |step|
            {
              step_order: step[:step_order],
              tool: step[:tool],
              params: step[:params],
              output_key: step[:output_key],
              description: step[:description],
              confidence: step[:confidence]
            }
          end,
          learned_patterns: infer_patterns_from_corrections(corrections),
          metadata: {
            recent_triggers: trigger_history.length,
            total_corrections: corrections.length
          }
        }
      end

      # Export to a file
      def export_to_file(workflow_id, file_path)
        data = export_workflow(workflow_id)
        return false unless data

        File.write(file_path, JSON.pretty_generate(data))
        true
      end

      # Import a workflow from a hash
      def import_workflow(data, rename_on_conflict: false)
        data = data.transform_keys(&:to_sym)

        name = data[:name]

        # Check for name conflict
        existing = Storage.load_workflow_by_name(name)
        if existing
          if rename_on_conflict
            # Find unique name
            counter = 1
            new_name = "#{name}-copy"
            while Storage.load_workflow_by_name(new_name)
              counter += 1
              new_name = "#{name}-copy-#{counter}"
            end
            name = new_name
          else
            # Update existing workflow
            return update_existing_workflow(existing[:id], data)
          end
        end

        # Create parsed workflow struct
        parsed = IntentParser::ParsedWorkflow.new(
          name: name,
          trigger: data[:trigger_config] || { type: :manual },
          sources: data[:sources] || [],
          transforms: data[:transforms] || [],
          destinations: data[:destinations] || [],
          raw_description: data[:description]
        )

        # Create step objects
        steps = (data[:steps] || []).map do |step_data|
          step_data = step_data.transform_keys(&:to_sym)
          Step.new(
            id: step_data[:step_order],
            tool: step_data[:tool],
            params: step_data[:params] || {},
            output_key: step_data[:output_key],
            description: step_data[:description]
          ).tap { |s| s.confidence = step_data[:confidence] || 0.0 }
        end

        # Generate steps if none provided
        if steps.empty?
          steps = PlanGenerator.generate(parsed)
        end

        # Save workflow
        workflow_id = Storage.save_workflow(parsed, steps)

        # Restore step confidences
        (data[:steps] || []).each do |step_data|
          step_data = step_data.transform_keys(&:to_sym)
          Storage.update_step_confidence(
            workflow_id,
            step_data[:step_order],
            step_data[:confidence] || 0.0
          )
        end

        workflow_id
      end

      # Import from a file
      def import_from_file(file_path, rename_on_conflict: false)
        return nil unless File.exist?(file_path)

        data = JSON.parse(File.read(file_path), symbolize_names: true)
        import_workflow(data, rename_on_conflict: rename_on_conflict)
      rescue JSON::ParserError => e
        nil
      end

      # Export all workflows to a directory
      def export_all(directory_path)
        FileUtils.mkdir_p(directory_path)

        workflows = Storage.list_workflows
        exported = []

        workflows.each do |wf|
          file_name = "#{wf[:name].gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
          file_path = File.join(directory_path, file_name)

          if export_to_file(wf[:id], file_path)
            exported << file_path
          end
        end

        exported
      end

      # Import all workflows from a directory
      def import_all(directory_path, rename_on_conflict: true)
        return [] unless Dir.exist?(directory_path)

        imported = []
        Dir.glob(File.join(directory_path, "*.json")).each do |file_path|
          workflow_id = import_from_file(file_path, rename_on_conflict: rename_on_conflict)
          imported << { file: file_path, workflow_id: workflow_id } if workflow_id
        end

        imported
      end

      private

      def update_existing_workflow(workflow_id, data)
        # Update workflow with new data (preserving ID)
        sql = <<~SQL
          UPDATE user_workflows SET
            description = '#{esc(data[:description])}',
            trigger_type = '#{esc(data[:trigger_type])}',
            trigger_config = '#{esc((data[:trigger_config] || {}).to_json)}',
            sources = '#{esc((data[:sources] || []).to_json)}',
            transforms = '#{esc((data[:transforms] || []).to_json)}',
            destinations = '#{esc((data[:destinations] || []).to_json)}',
            updated_at = datetime('now')
          WHERE id = #{workflow_id};
        SQL
        Ruboto.run_sql(sql)

        # Update steps
        Ruboto.run_sql("DELETE FROM workflow_steps WHERE workflow_id = #{workflow_id};")

        (data[:steps] || []).each do |step_data|
          step_data = step_data.transform_keys(&:to_sym)
          sql = <<~SQL
            INSERT INTO workflow_steps (workflow_id, step_order, tool, params, output_key, description, confidence)
            VALUES (#{workflow_id}, #{step_data[:step_order]}, '#{esc(step_data[:tool])}',
                    '#{esc((step_data[:params] || {}).to_json)}', '#{esc(step_data[:output_key])}',
                    '#{esc(step_data[:description])}', #{step_data[:confidence] || 0.0});
          SQL
          Ruboto.run_sql(sql)
        end

        workflow_id
      end

      def infer_patterns_from_corrections(corrections)
        return [] if corrections.empty?

        # Group by correction type
        by_type = corrections.group_by { |c| c[:correction_type] }

        patterns = []
        by_type.each do |type, items|
          next if items.length < 2

          patterns << {
            type: type,
            count: items.length,
            examples: items.first(3).map { |i| { original: i[:original_value], corrected: i[:corrected_value] } }
          }
        end

        patterns
      end

      def esc(str)
        str.to_s.gsub("'", "''")
      end
    end
  end
end
