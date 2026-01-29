# frozen_string_literal: true

require "open3"

module Ruboto
  module Osascript
    OSASCRIPT_TIMEOUT = 180  # 3 minutes for very slow Mail.app with large mailboxes

    def run_applescript(script)
      run_osascript("osascript", "-e", script)
    end

    def run_jxa(script)
      run_osascript("osascript", "-l", "JavaScript", "-e", script)
    end

    private

    def run_osascript(*cmd)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(*cmd, out: out_w, err: err_w)
      out_w.close
      err_w.close

      # Read output in threads to avoid pipe buffer deadlock
      out_thread = Thread.new { out_r.read }
      err_thread = Thread.new { err_r.read }

      # Wait for process with timeout
      deadline = Time.now + OSASCRIPT_TIMEOUT
      status = nil
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        break if status
        if Time.now > deadline
          Process.kill("TERM", pid) rescue nil
          Process.waitpid2(pid) rescue nil
          out_r.close rescue nil
          err_r.close rescue nil
          return { success: false, output: "", error: "Timed out after #{OSASCRIPT_TIMEOUT}s" }
        end
        sleep 0.05
      end

      out = out_thread.value
      err = err_thread.value
      out_r.close rescue nil
      err_r.close rescue nil

      if status.success?
        { success: true, output: out.chomp, error: "" }
      else
        { success: false, output: "", error: err.chomp }
      end
    rescue Errno::ENOENT
      { success: false, output: "", error: "osascript not found — macOS required" }
    rescue => e
      { success: false, output: "", error: e.message }
    end
  end
end
