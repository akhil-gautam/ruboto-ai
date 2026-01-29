# frozen_string_literal: true

require "json"

module Ruboto
  module Workflow
    module Storage
      extend self

      def save_workflow(parsed, steps)
        name = esc(parsed.name)
        description = esc(parsed.raw_description)
        trigger_type = esc(parsed.trigger[:type].to_s)
        trigger_config = esc(parsed.trigger.to_json)
        sources = esc(parsed.sources.to_json)
        transforms = esc(parsed.transforms.to_json)
        destinations = esc(parsed.destinations.to_json)

        sql = <<~SQL
          INSERT INTO user_workflows (name, description, trigger_type, trigger_config, sources, transforms, destinations)
          VALUES ('#{name}', '#{description}', '#{trigger_type}', '#{trigger_config}', '#{sources}', '#{transforms}', '#{destinations}')
          ON CONFLICT(name) DO UPDATE SET
            description='#{description}',
            trigger_type='#{trigger_type}',
            trigger_config='#{trigger_config}',
            sources='#{sources}',
            transforms='#{transforms}',
            destinations='#{destinations}',
            updated_at=datetime('now');
        SQL
        Ruboto.run_sql(sql)

        workflow_id = Ruboto.run_sql("SELECT id FROM user_workflows WHERE name='#{name}';").strip.to_i

        # Delete existing steps and re-insert
        Ruboto.run_sql("DELETE FROM workflow_steps WHERE workflow_id=#{workflow_id};")

        steps.each_with_index do |step, idx|
          step_sql = <<~SQL
            INSERT INTO workflow_steps (workflow_id, step_order, tool, params, output_key, description, confidence)
            VALUES (#{workflow_id}, #{idx + 1}, '#{esc(step.tool)}', '#{esc(step.params.to_json)}', '#{esc(step.output_key.to_s)}', '#{esc(step.description)}', #{step.confidence});
          SQL
          Ruboto.run_sql(step_sql)
        end

        workflow_id
      end

      def load_workflow(id)
        sql = "SELECT id, name, description, trigger_type, trigger_config, sources, transforms, destinations, overall_confidence, run_count, success_count, enabled FROM user_workflows WHERE id=#{id.to_i};"
        row = Ruboto.run_sql(sql).strip
        return nil if row.empty?

        cols = row.split("|")
        {
          id: cols[0].to_i,
          name: cols[1],
          description: cols[2],
          trigger_type: cols[3],
          trigger_config: JSON.parse(cols[4] || "{}"),
          sources: JSON.parse(cols[5] || "[]"),
          transforms: JSON.parse(cols[6] || "[]"),
          destinations: JSON.parse(cols[7] || "[]"),
          overall_confidence: cols[8].to_f,
          run_count: cols[9].to_i,
          success_count: cols[10].to_i,
          enabled: cols[11].to_i == 1
        }
      rescue JSON::ParserError
        nil
      end

      def load_workflow_by_name(name)
        sql = "SELECT id FROM user_workflows WHERE name='#{esc(name)}';"
        id = Ruboto.run_sql(sql).strip.to_i
        return nil if id == 0
        load_workflow(id)
      end

      def load_steps(workflow_id)
        sql = "SELECT step_order, tool, params, output_key, description, confidence FROM workflow_steps WHERE workflow_id=#{workflow_id.to_i} ORDER BY step_order;"
        rows = Ruboto.run_sql(sql).strip
        return [] if rows.empty?

        rows.split("\n").map do |row|
          cols = row.split("|")
          {
            step_order: cols[0].to_i,
            tool: cols[1],
            params: JSON.parse(cols[2] || "{}"),
            output_key: cols[3],
            description: cols[4],
            confidence: cols[5].to_f
          }
        end
      rescue JSON::ParserError
        []
      end

      def list_workflows
        sql = "SELECT id, name, description, trigger_type, overall_confidence, run_count, enabled FROM user_workflows ORDER BY run_count DESC;"
        rows = Ruboto.run_sql(sql).strip
        return [] if rows.empty?

        rows.split("\n").map do |row|
          cols = row.split("|")
          {
            id: cols[0].to_i,
            name: cols[1],
            description: cols[2],
            trigger_type: cols[3],
            overall_confidence: cols[4].to_f,
            run_count: cols[5].to_i,
            enabled: cols[6].to_i == 1
          }
        end
      end

      def start_run(workflow_id)
        sql = "INSERT INTO workflow_runs (workflow_id) VALUES (#{workflow_id.to_i}); SELECT MAX(id) FROM workflow_runs WHERE workflow_id=#{workflow_id.to_i};"
        Ruboto.run_sql(sql).strip.to_i
      end

      def complete_run(run_id, status, state_snapshot, log)
        sql = <<~SQL
          UPDATE workflow_runs
          SET status='#{esc(status)}',
              completed_at=datetime('now'),
              state_snapshot='#{esc(state_snapshot.to_json)}',
              log='#{esc(log.to_json)}'
          WHERE id=#{run_id.to_i};
        SQL
        Ruboto.run_sql(sql)
      end

      def update_step_confidence(workflow_id, step_order, confidence)
        sql = "UPDATE workflow_steps SET confidence=#{confidence.to_f} WHERE workflow_id=#{workflow_id.to_i} AND step_order=#{step_order.to_i};"
        Ruboto.run_sql(sql)
      end

      def record_correction(workflow_id, step_order, correction_type, original, corrected)
        sql = <<~SQL
          INSERT INTO step_corrections (workflow_id, step_order, correction_type, original_value, corrected_value)
          VALUES (#{workflow_id.to_i}, #{step_order.to_i}, '#{esc(correction_type)}', '#{esc(original.to_s)}', '#{esc(corrected.to_s)}');
        SQL
        Ruboto.run_sql(sql)
      end

      def increment_run_count(workflow_id, success)
        if success
          sql = "UPDATE user_workflows SET run_count = run_count + 1, success_count = success_count + 1, updated_at = datetime('now') WHERE id=#{workflow_id.to_i};"
        else
          sql = "UPDATE user_workflows SET run_count = run_count + 1, updated_at = datetime('now') WHERE id=#{workflow_id.to_i};"
        end
        Ruboto.run_sql(sql)
      end

      def update_overall_confidence(workflow_id)
        sql = "SELECT AVG(confidence) FROM workflow_steps WHERE workflow_id=#{workflow_id.to_i};"
        avg = Ruboto.run_sql(sql).strip.to_f
        Ruboto.run_sql("UPDATE user_workflows SET overall_confidence=#{avg} WHERE id=#{workflow_id.to_i};")
      end

      private

      def esc(str)
        str.to_s.gsub("'", "''")
      end
    end
  end
end
