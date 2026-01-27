# frozen_string_literal: true

module Ruboto
  module Safety
    def confirm_action(description)
      print "\n\033[33m⚠ Action: #{description}\033[0m\n"
      print "\033[1mProceed? [y/N]:\033[0m "
      $stdout.flush
      answer = $stdin.gets&.strip&.downcase
      answer == "y" || answer == "yes"
    end
  end
end
