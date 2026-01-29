# frozen_string_literal: true

require "json"

module Ruboto
  module Workflow
    module History
      extend self

      # Get run history for a specific workflow
      def get_runs(workflow_id, limit: 20, status: nil, include_log: false)
        conditions = ["workflow_id = #{workflow_id.to_i}"]
        conditions << "status = '#{esc(status)}'" if status

        sql = <<~SQL
          SELECT id, workflow_id, status, started_at, completed_at, state_snapshot, log
          FROM workflow_runs
          WHERE #{conditions.join(' AND ')}
          ORDER BY started_at DESC
          LIMIT #{limit.to_i};
        SQL

        parse_runs(Ruboto.run_sql(sql), include_log: include_log)
      end

      # Get run history across all workflows
      def get_all_runs(limit: 20, status: nil, include_log: false)
        conditions = ["1=1"]
        conditions << "r.status = '#{esc(status)}'" if status

        sql = <<~SQL
          SELECT r.id, r.workflow_id, w.name as workflow_name, r.status,
                 r.started_at, r.completed_at, r.state_snapshot, r.log
          FROM workflow_runs r
          JOIN user_workflows w ON r.workflow_id = w.id
          WHERE #{conditions.join(' AND ')}
          ORDER BY r.started_at DESC
          LIMIT #{limit.to_i};
        SQL

        parse_runs(Ruboto.run_sql(sql), include_log: include_log, include_name: true)
      end

      # Get summary statistics for a workflow
      def get_stats(workflow_id)
        sql = <<~SQL
          SELECT
            COUNT(*) as total_runs,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as successful,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
            AVG(julianday(completed_at) - julianday(started_at)) * 86400 as avg_duration_sec
          FROM workflow_runs
          WHERE workflow_id = #{workflow_id.to_i} AND completed_at IS NOT NULL;
        SQL

        result = Ruboto.run_sql(sql).strip
        return default_stats if result.empty?

        cols = result.split("|")
        {
          total_runs: cols[0].to_i,
          successful: cols[1].to_i,
          failed: cols[2].to_i,
          success_rate: cols[0].to_i > 0 ? (cols[1].to_f / cols[0].to_f * 100).round(1) : 0,
          avg_duration_seconds: cols[3].to_f.round(2)
        }
      end

      # Get recent errors for a workflow
      def get_recent_errors(workflow_id, limit: 5)
        sql = <<~SQL
          SELECT id, started_at, log
          FROM workflow_runs
          WHERE workflow_id = #{workflow_id.to_i} AND status = 'failed'
          ORDER BY started_at DESC
          LIMIT #{limit.to_i};
        SQL

        result = Ruboto.run_sql(sql).strip
        return [] if result.empty?

        result.split("\n").map do |row|
          cols = row.split("|")
          log = parse_log(cols[2])
          error_events = log.select { |e| e[:event] == "failed" || e[:error] }

          {
            run_id: cols[0].to_i,
            timestamp: cols[1],
            errors: error_events.map { |e| e[:error] || e[:data]&.dig(:error) }.compact
          }
        end
      end

      private

      def parse_runs(result, include_log: false, include_name: false)
        return [] if result.strip.empty?

        result.strip.split("\n").map do |row|
          cols = row.split("|")
          offset = include_name ? 1 : 0

          run = {
            id: cols[0].to_i,
            workflow_id: cols[1].to_i,
            status: cols[2 + offset],
            started_at: cols[3 + offset],
            completed_at: cols[4 + offset]
          }

          run[:workflow_name] = cols[2] if include_name
          run[:state] = parse_json(cols[5 + offset]) if include_log
          run[:log] = parse_log(cols[6 + offset]) if include_log

          # Calculate duration
          if run[:started_at] && run[:completed_at]
            begin
              start_time = Time.parse(run[:started_at])
              end_time = Time.parse(run[:completed_at])
              run[:duration_seconds] = (end_time - start_time).round(2)
            rescue
              run[:duration_seconds] = nil
            end
          end

          run
        end
      end

      def parse_log(log_str)
        return [] if log_str.nil? || log_str.empty?
        JSON.parse(log_str, symbolize_names: true)
      rescue JSON::ParserError
        []
      end

      def parse_json(json_str)
        return {} if json_str.nil? || json_str.empty?
        JSON.parse(json_str, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def default_stats
        { total_runs: 0, successful: 0, failed: 0, success_rate: 0, avg_duration_seconds: 0 }
      end

      def esc(str)
        str.to_s.gsub("'", "''")
      end
    end
  end
end
