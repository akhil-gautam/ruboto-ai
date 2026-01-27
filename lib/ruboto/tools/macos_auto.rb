# frozen_string_literal: true

require "json"

module Ruboto
  module Tools
    module MacosAuto
      def tool_macos_auto(args)
        action = args["action"]

        case action
        when "open_app"
          app = args["app_name"]
          return "error: app_name required" unless app
          result = run_applescript("tell application \"#{app.gsub('"', '\\"')}\" to activate")
          result[:success] ? "Opened #{app}" : "error: #{result[:error]}"

        when "notify"
          title = (args["title"] || "Ruboto").gsub('"', '\\"')
          body = (args["body"] || "").gsub('"', '\\"')
          result = run_applescript("display notification \"#{body}\" with title \"#{title}\"")
          result[:success] ? "Notification sent" : "error: #{result[:error]}"

        when "clipboard_read"
          result = run_applescript("the clipboard")
          result[:success] ? result[:output] : "error: #{result[:error]}"

        when "clipboard_write"
          text = args["value"]
          return "error: value required" unless text
          escaped = text.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
          result = run_applescript("set the clipboard to \"#{escaped}\"")
          result[:success] ? "Copied to clipboard" : "error: #{result[:error]}"

        when "calendar_today"
          jxa = <<~JS.strip
            var app = Application("Calendar");
            var now = new Date();
            var start = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0);
            var end_ = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59);
            var cals = app.calendars();
            var events = [];
            for (var c = 0; c < cals.length; c++) {
              var evts = cals[c].events.whose({startDate: {_greaterThan: start}, startDate: {_lessThan: end_}})();
              for (var e = 0; e < evts.length; e++) {
                events.push({
                  title: evts[e].summary(),
                  start: evts[e].startDate().toLocaleTimeString(),
                  end: evts[e].endDate().toLocaleTimeString(),
                  location: evts[e].location() || ""
                });
              }
            }
            JSON.stringify(events);
          JS
          result = run_jxa(jxa)
          if result[:success]
            events = JSON.parse(result[:output]) rescue []
            if events.empty?
              "No events today."
            else
              events.map { |e| "#{e['start']}-#{e['end']}: #{e['title']}#{e['location'].empty? ? '' : " (#{e['location']})"}" }.join("\n")
            end
          else
            "error: #{result[:error]}"
          end

        when "reminder_add"
          title = args["title"]
          return "error: title required" unless title
          escaped_title = title.gsub('"', '\\"')
          due = args["due_date"]
          if due
            script = "tell application \"Reminders\"\nmake new reminder with properties {name:\"#{escaped_title}\", due date:date \"#{due.gsub('"', '\\"')}\"}\nend tell"
          else
            script = "tell application \"Reminders\"\nmake new reminder with properties {name:\"#{escaped_title}\"}\nend tell"
          end
          result = run_applescript(script)
          result[:success] ? "Reminder created: #{title}" : "error: #{result[:error]}"

        when "note_create"
          title = args["title"] || "Untitled"
          body = args["body"] || ""
          folder = args["folder"] || "Notes"
          escaped_title = title.gsub('"', '\\"')
          escaped_body = body.gsub('"', '\\"')
          escaped_folder = folder.gsub('"', '\\"')
          script = "tell application \"Notes\"\ntell folder \"#{escaped_folder}\"\nmake new note with properties {name:\"#{escaped_title}\", body:\"#{escaped_body}\"}\nend tell\nend tell"
          result = run_applescript(script)
          result[:success] ? "Note created: #{title}" : "error: #{result[:error]}"

        when "mail_send"
          to = args["to"]
          subject = args["subject"] || ""
          body = args["body"] || ""
          return "error: 'to' address required" unless to

          description = "Send email to #{to}: \"#{subject}\""
          return "Cancelled by user." unless confirm_action(description)

          escaped_to = to.gsub('"', '\\"')
          escaped_subj = subject.gsub('"', '\\"')
          escaped_body = body.gsub('"', '\\"')
          script = <<~APPLESCRIPT.strip
            tell application "Mail"
              set newMsg to make new outgoing message with properties {subject:"#{escaped_subj}", content:"#{escaped_body}", visible:false}
              tell newMsg
                make new to recipient with properties {address:"#{escaped_to}"}
              end tell
              send newMsg
            end tell
          APPLESCRIPT
          result = run_applescript(script)
          result[:success] ? "Email sent to #{to}" : "error: #{result[:error]}"

        when "mail_read"
          limit = (args["limit"] || 5).to_i.clamp(1, 20)
          jxa = <<~JS.strip
            var mail = Application("Mail");
            var inbox = mail.inbox();
            var msgs = inbox.messages();
            var results = [];
            var count = Math.min(#{limit}, msgs.length);
            for (var i = 0; i < count; i++) {
              var m = msgs[i];
              results.push({
                from: m.sender(),
                subject: m.subject(),
                date: m.dateReceived().toLocaleString(),
                read: m.readStatus()
              });
            }
            JSON.stringify(results);
          JS
          result = run_jxa(jxa)
          if result[:success]
            emails = JSON.parse(result[:output]) rescue []
            if emails.empty?
              "No emails found."
            else
              emails.map { |e| "#{e['read'] ? ' ' : '*'} #{e['from']}: #{e['subject']} (#{e['date']})" }.join("\n")
            end
          else
            "error: #{result[:error]}"
          end

        when "finder_reveal"
          path = args["path"]
          return "error: path required" unless path
          escaped = path.gsub('"', '\\"')
          result = run_applescript("tell application \"Finder\" to reveal POSIX file \"#{escaped}\"")
          run_applescript("tell application \"Finder\" to activate") if result[:success]
          result[:success] ? "Opened Finder at #{path}" : "error: #{result[:error]}"

        else
          "error: unknown action '#{action}'. Use: open_app, notify, clipboard_read, clipboard_write, calendar_today, reminder_add, note_create, mail_send, mail_read, finder_reveal"
        end
      rescue => e
        "error: #{e.message}"
      end

      def macos_auto_schema
        {
          type: "function",
          name: "macos_auto",
          description: "Control macOS apps: open apps, notifications, clipboard, calendar, reminders, notes, email, Finder. Use for any system-level automation.",
          parameters: {
            type: "object",
            properties: {
              action: {
                type: "string",
                description: "Action to perform",
                enum: ["open_app", "notify", "clipboard_read", "clipboard_write", "calendar_today", "reminder_add", "note_create", "mail_send", "mail_read", "finder_reveal"]
              },
              app_name: { type: "string", description: "App name (for open_app)" },
              title: { type: "string", description: "Title (for notify, reminder_add, note_create)" },
              body: { type: "string", description: "Body text (for notify, note_create, mail_send)" },
              to: { type: "string", description: "Email address (for mail_send)" },
              subject: { type: "string", description: "Email subject (for mail_send)" },
              path: { type: "string", description: "File/folder path (for finder_reveal)" },
              folder: { type: "string", description: "Notes folder (for note_create, default: Notes)" },
              value: { type: "string", description: "Text value (for clipboard_write)" },
              due_date: { type: "string", description: "Due date string (for reminder_add, e.g. 'January 28, 2026 9:00 AM')" },
              limit: { type: "integer", description: "Max results (for mail_read, default: 5)" }
            },
            required: ["action"]
          }
        }
      end
    end
  end
end
