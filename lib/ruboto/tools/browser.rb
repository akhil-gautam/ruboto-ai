# frozen_string_literal: true

require "json"

module Ruboto
  module Tools
    module Browser
      MAX_PAGE_TEXT = 10_000

      def tool_browser(args)
        action = args["action"]

        case action
        when "open_url"
          url = args["url"]
          return "error: url required" unless url
          escaped = url.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\"\nactivate\nopen location \"#{escaped}\"\nend tell")
          result[:success] ? "Opened #{url}" : "error: #{result[:error]}"

        when "get_url"
          result = run_applescript("tell application \"Safari\" to get URL of current tab of front window")
          result[:success] ? result[:output] : "error: #{result[:error]}"

        when "get_title"
          result = run_applescript("tell application \"Safari\" to get name of current tab of front window")
          result[:success] ? result[:output] : "error: #{result[:error]}"

        when "get_text"
          result = run_applescript("tell application \"Safari\" to do JavaScript \"document.body.innerText\" in current tab of front window")
          if result[:success]
            text = result[:output]
            text.length > MAX_PAGE_TEXT ? text[0, MAX_PAGE_TEXT] + "\n... (truncated)" : text
          else
            if result[:error].include?("not allowed") || result[:error].include?("JavaScript")
              "error: Safari's 'Allow JavaScript from Apple Events' is disabled. Enable it in Safari > Develop > Allow JavaScript from Apple Events"
            else
              "error: #{result[:error]}"
            end
          end

        when "get_links"
          js = "JSON.stringify(Array.from(document.querySelectorAll('a[href]')).slice(0,100).map(a=>({text:a.innerText.trim().substring(0,80),href:a.href})))"
          escaped_js = js.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped_js}\" in current tab of front window")
          if result[:success]
            links = JSON.parse(result[:output]) rescue []
            links.empty? ? "No links found." : links.map { |l| "#{l['text']} -> #{l['href']}" }.join("\n")
          else
            "error: #{result[:error]}"
          end

        when "run_js"
          js_code = args["js_code"]
          return "error: js_code required" unless js_code

          description = "Run JavaScript in Safari: #{js_code[0, 80]}#{js_code.length > 80 ? '...' : ''}"
          return "Cancelled by user." unless confirm_action(description)

          escaped = js_code.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped}\" in current tab of front window")
          result[:success] ? (result[:output].empty? ? "JS executed (no return value)" : result[:output]) : "error: #{result[:error]}"

        when "click"
          selector = args["selector"]
          return "error: selector required" unless selector
          escaped_sel = selector.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("'", "\\\\'")
          js = "document.querySelector('#{escaped_sel}').click(); 'clicked'"
          escaped_js = js.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped_js}\" in current tab of front window")
          result[:success] ? "Clicked #{selector}" : "error: #{result[:error]}"

        when "fill"
          selector = args["selector"]
          value = args["value"]
          return "error: selector and value required" unless selector && value
          escaped_sel = selector.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("'", "\\\\'")
          escaped_val = value.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("'", "\\\\'")
          js = "var el=document.querySelector('#{escaped_sel}'); el.value='#{escaped_val}'; el.dispatchEvent(new Event('input',{bubbles:true})); 'filled'"
          escaped_js = js.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped_js}\" in current tab of front window")
          result[:success] ? "Filled #{selector}" : "error: #{result[:error]}"

        when "screenshot"
          tmp = "/tmp/ruboto_screenshot_#{Time.now.to_i}.png"
          result = run_applescript("do shell script \"screencapture -l $(osascript -e 'tell app \\\"Safari\\\" to id of window 1') #{tmp}\"")
          if result[:success] && File.exist?(tmp)
            "Screenshot saved: #{tmp}"
          else
            "error: #{result[:error]}"
          end

        when "tabs"
          jxa = <<~JS.strip
            var safari = Application("Safari");
            var wins = safari.windows();
            var tabs = [];
            for (var w = 0; w < wins.length; w++) {
              var wtabs = wins[w].tabs();
              for (var t = 0; t < wtabs.length; t++) {
                tabs.push({index: tabs.length, title: wtabs[t].name(), url: wtabs[t].url()});
              }
            }
            JSON.stringify(tabs);
          JS
          result = run_jxa(jxa)
          if result[:success]
            tabs_list = JSON.parse(result[:output]) rescue []
            tabs_list.empty? ? "No tabs open." : tabs_list.map { |t| "[#{t['index']}] #{t['title']} - #{t['url']}" }.join("\n")
          else
            "error: #{result[:error]}"
          end

        when "switch_tab"
          idx = args["tab_index"]
          return "error: tab_index required" unless idx
          idx = idx.to_i
          jxa = <<~JS.strip
            var safari = Application("Safari");
            var wins = safari.windows();
            var counter = 0;
            for (var w = 0; w < wins.length; w++) {
              var wtabs = wins[w].tabs();
              for (var t = 0; t < wtabs.length; t++) {
                if (counter === #{idx}) {
                  wins[w].currentTab = wtabs[t];
                  safari.activate();
                  JSON.stringify({title: wtabs[t].name(), url: wtabs[t].url()});
                }
                counter++;
              }
            }
            "not found";
          JS
          result = run_jxa(jxa)
          result[:success] ? "Switched to tab #{idx}: #{result[:output]}" : "error: #{result[:error]}"

        else
          "error: unknown action '#{action}'. Use: open_url, get_url, get_title, get_text, get_links, run_js, click, fill, screenshot, tabs, switch_tab"
        end
      rescue => e
        "error: #{e.message}"
      end

      def browser_schema
        {
          type: "function",
          name: "browser",
          description: "Control Safari browser: open URLs, read page text/links, fill forms, click elements, run JavaScript, manage tabs. Use for any web interaction.",
          parameters: {
            type: "object",
            properties: {
              action: {
                type: "string",
                description: "Action to perform",
                enum: ["open_url", "get_url", "get_title", "get_text", "get_links", "run_js", "click", "fill", "screenshot", "tabs", "switch_tab"]
              },
              url: { type: "string", description: "URL to open (for open_url)" },
              selector: { type: "string", description: "CSS selector (for click, fill)" },
              value: { type: "string", description: "Value to fill (for fill)" },
              js_code: { type: "string", description: "JavaScript code (for run_js)" },
              tab_index: { type: "integer", description: "Tab index (for switch_tab)" }
            },
            required: ["action"]
          }
        }
      end
    end
  end
end
