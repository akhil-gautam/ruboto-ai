# frozen_string_literal: true

require "open3"
require "timeout"

module Ruboto
  module Osascript
    TIMEOUT = 30

    def run_applescript(script)
      Timeout.timeout(TIMEOUT) do
        stdout, stderr, status = Open3.capture3("osascript", "-e", script)
        if status.success?
          { success: true, output: stdout.chomp, error: "" }
        else
          { success: false, output: "", error: stderr.chomp }
        end
      end
    rescue Timeout::Error
      { success: false, output: "", error: "Timed out after #{TIMEOUT}s" }
    rescue Errno::ENOENT
      { success: false, output: "", error: "osascript not found — macOS required" }
    rescue => e
      { success: false, output: "", error: e.message }
    end

    def run_jxa(script)
      Timeout.timeout(TIMEOUT) do
        stdout, stderr, status = Open3.capture3("osascript", "-l", "JavaScript", "-e", script)
        if status.success?
          { success: true, output: stdout.chomp, error: "" }
        else
          { success: false, output: "", error: stderr.chomp }
        end
      end
    rescue Timeout::Error
      { success: false, output: "", error: "Timed out after #{TIMEOUT}s" }
    rescue Errno::ENOENT
      { success: false, output: "", error: "osascript not found — macOS required" }
    rescue => e
      { success: false, output: "", error: e.message }
    end
  end
end
