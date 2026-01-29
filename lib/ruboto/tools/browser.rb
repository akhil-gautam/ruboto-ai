# frozen_string_literal: true

require "json"
require "fileutils"
require "ferrum"

module Ruboto
  module Tools
    module Browser
      MAX_PAGE_TEXT = 10_000

      @browser = nil
      @headless = false

      class << self
        attr_accessor :headless
      end

      def browser
        Browser.instance
      end

      PROFILE_DIR = File.expand_path("~/.ruboto/chrome_profile")

      def self.instance
        @browser ||= begin
          options = {
            headless: @headless || ENV["RUBOTO_HEADLESS"] == "1",
            timeout: 30,
            process_timeout: 30,
            window_size: [1280, 800]
          }

          # Use persistent ruboto profile (preserves logins) unless disabled
          unless ENV["RUBOTO_FRESH_PROFILE"] == "1"
            FileUtils.mkdir_p(PROFILE_DIR)
            options[:browser_options] = { "user-data-dir" => PROFILE_DIR }
          end

          b = Ferrum::Browser.new(**options)
          at_exit { b.quit rescue nil }
          b
        end
      end

      def self.reset!
        @browser&.quit rescue nil
        @browser = nil
      end

      def tool_browser(args)
        action = args["action"]

        case action
        when "open_url"
          url = args["url"]
          return "error: url required" unless url
          browser.go_to(url)
          "Opened #{url}"

        when "get_url"
          browser.current_url

        when "get_title"
          browser.current_title

        when "get_text"
          text = browser.body.text rescue browser.at_css("body")&.text || ""
          text.length > MAX_PAGE_TEXT ? text[0, MAX_PAGE_TEXT] + "\n... (truncated)" : text

        when "get_links"
          links = browser.css("a[href]").first(100).map do |a|
            { "text" => a.text.strip[0, 80], "href" => a.attribute("href") }
          end
          links.empty? ? "No links found." : links.map { |l| "#{l['text']} -> #{l['href']}" }.join("\n")

        when "run_js"
          js_code = args["js_code"]
          return "error: js_code required" unless js_code

          description = "Run JavaScript in Chrome: #{js_code[0, 80]}#{js_code.length > 80 ? '...' : ''}"
          return "Cancelled by user." unless confirm_action(description)

          result = browser.evaluate(js_code)
          result.nil? ? "JS executed (no return value)" : result.to_s

        when "click"
          selector = args["selector"]
          return "error: selector required" unless selector
          element = browser.at_css(selector)
          return "error: element not found for selector '#{selector}'" unless element
          element.click
          "Clicked #{selector}"

        when "fill"
          selector = args["selector"]
          value = args["value"]
          return "error: selector and value required" unless selector && value
          element = browser.at_css(selector)
          return "error: element not found for selector '#{selector}'" unless element
          element.focus.type(value)
          "Filled #{selector}"

        when "screenshot"
          tmp = "/tmp/ruboto_screenshot_#{Time.now.to_i}.png"
          browser.screenshot(path: tmp)
          File.exist?(tmp) ? "Screenshot saved: #{tmp}" : "error: screenshot failed"

        when "tabs"
          tabs_list = browser.contexts.flat_map(&:targets).each_with_index.map do |target, idx|
            { "index" => idx, "title" => target.title, "url" => target.url }
          end
          tabs_list.empty? ? "No tabs open." : tabs_list.map { |t| "[#{t['index']}] #{t['title']} - #{t['url']}" }.join("\n")

        when "switch_tab"
          idx = args["tab_index"]
          return "error: tab_index required" unless idx
          idx = idx.to_i
          targets = browser.contexts.flat_map(&:targets)
          return "error: tab index out of range" if idx < 0 || idx >= targets.length
          target = targets[idx]
          browser.switch_to_window(target.page)
          "Switched to tab #{idx}: #{target.title}"

        when "new_tab"
          url = args["url"]
          browser.create_page
          browser.go_to(url) if url
          url ? "Opened new tab with #{url}" : "Opened new tab"

        when "close_tab"
          browser.page.close
          "Closed current tab"

        when "wait"
          selector = args["selector"]
          timeout = args["timeout"] || 10
          return "error: selector required" unless selector
          browser.at_css(selector, wait: timeout)
          "Element found: #{selector}"

        when "config"
          headless = args["headless"]
          unless headless.nil?
            Browser.headless = headless
            Browser.reset!
            return "Browser set to #{headless ? 'headless' : 'visible'} mode (will apply on next action)"
          end
          "Current config: headless=#{Browser.headless}"

        else
          "error: unknown action '#{action}'. Use: open_url, get_url, get_title, get_text, get_links, run_js, click, fill, screenshot, tabs, switch_tab, new_tab, close_tab, wait, config"
        end
      rescue Ferrum::TimeoutError
        "error: page load timeout"
      rescue Ferrum::NodeNotFoundError
        "error: element not found"
      rescue Ferrum::JavaScriptError => e
        "error: JavaScript error - #{e.message}"
      rescue => e
        Browser.reset! if e.message.include?("browser") || e.message.include?("closed")
        "error: #{e.message}"
      end

      def browser_schema
        {
          type: "function",
          name: "browser",
          description: <<~DESC.strip,
            Control Chrome browser for web interactions using Ferrum.

            WORKFLOW PRINCIPLES:
            1. Browser stays open across calls - state is preserved
            2. PREFER open_url over clicking - URL navigation is more reliable
            3. Use wait action for SPAs that load content dynamically
            4. For FORMS: use get_text to identify inputs, fill each field, then click submit

            COMMON PATTERNS:
            - Gmail search: open_url with mail.google.com/mail/u/0/#search/query
            - Fill form: get_text → identify inputs → fill each → click submit
            - Wait for content: wait with selector before interacting
          DESC
          parameters: {
            type: "object",
            properties: {
              action: {
                type: "string",
                description: "Action to perform",
                enum: ["open_url", "get_url", "get_title", "get_text", "get_links", "click", "fill", "run_js", "screenshot", "tabs", "switch_tab", "new_tab", "close_tab", "wait", "config"]
              },
              url: { type: "string", description: "URL to open (for open_url, new_tab)" },
              selector: { type: "string", description: "CSS selector (for click, fill, wait)" },
              value: { type: "string", description: "Value to fill (for fill)" },
              js_code: { type: "string", description: "JavaScript code (for run_js). Requires user confirmation." },
              tab_index: { type: "integer", description: "Tab index (for switch_tab)" },
              timeout: { type: "integer", description: "Timeout in seconds (for wait, default 10)" },
              headless: { type: "boolean", description: "Run headless (for config)" }
            },
            required: ["action"]
          }
        }
      end
    end
  end
end
