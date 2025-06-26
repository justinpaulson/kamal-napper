#!/usr/bin/env ruby

require "webrick"
require "json"

# Load Kamal Napper library
$LOAD_PATH.unshift(File.expand_path("lib", File.dirname(__FILE__)))
require "kamal_napper"

# Create a simple web server
server = WEBrick::HTTPServer.new(
  :Port => 80,
  :BindAddress => "0.0.0.0",
  :AccessLog => []
)

# Health check endpoint - exactly what Kamal needs
server.mount_proc("/health") do |req, res|
  res.status = 200
  res['Content-Type'] = 'application/json'
  res.body = '{"status":"ok","service":"kamal-napper","timestamp":"' + Time.now.to_s + '"}'
end

# UP endpoint for Kamal proxy
server.mount_proc("/up") do |req, res|
  res.status = 200
  res['Content-Type'] = 'text/plain'
  res.body = "OK"
end

# API endpoint for app status information (JSON)
server.mount_proc("/api/apps") do |req, res|
  supervisor = get_supervisor
  status_info = supervisor.status
  
  res.status = 200
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate({
    apps: status_info[:apps].transform_values do |app_info| 
      {
        state: app_info[:current_state],
        time_in_state: app_info[:time_in_state],
        time_in_state_formatted: format_duration(app_info[:time_in_state]),
        state_changed_at: app_info[:state_changed_at],
        is_active: [:running, :idle].include?(app_info[:current_state])
      }
    end,
    app_count: status_info[:app_count],
    poll_interval: status_info[:poll_interval],
    timestamp: Time.now.iso8601
  })
end

# Create supervisor instance to access app states
def get_supervisor
  @logger ||= KamalNapper::Logger.new
  @config ||= KamalNapper::ConfigLoader.new
  KamalNapper::Supervisor.new(logger: @logger, config: @config)
end

# Get state CSS class based on app state
def state_class(state)
  case state
  when :running then "state-running"
  when :idle then "state-idle"
  when :starting then "state-starting"
  when :stopping then "state-stopping"
  when :stopped then "state-stopped"
  else "state-unknown"
  end
end

# Format duration nicely
def format_duration(seconds)
  if seconds < 60
    "#{seconds.round}s"
  elsif seconds < 3600
    "#{(seconds / 60).round}m"
  else
    "#{(seconds / 3600).round(1)}h"
  end
end

# Default page with app status information
server.mount_proc("/") do |req, res|
  res.status = 200
  res['Content-Type'] = 'text/html'
  
  # Get app status information
  supervisor = get_supervisor
  status_info = supervisor.status
  
  res.body = <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
      <title>Kamal Napper</title>
      <style>
        body { font-family: sans-serif; margin: 20px; line-height: 1.5; }
        h1 { color: #333; margin-bottom: 20px; }
        h2 { color: #555; margin-top: 20px; }
        .status-container { margin-top: 20px; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { text-align: left; padding: 10px; border-bottom: 1px solid #ddd; }
        th { background-color: #f2f2f2; }
        tr:hover { background-color: #f5f5f5; }
        .state-running { background-color: #d4edda; color: #155724; padding: 3px 8px; border-radius: 4px; }
        .state-idle { background-color: #fff3cd; color: #856404; padding: 3px 8px; border-radius: 4px; }
        .state-stopped { background-color: #f8d7da; color: #721c24; padding: 3px 8px; border-radius: 4px; }
        .state-starting, .state-stopping { background-color: #d1ecf1; color: #0c5460; padding: 3px 8px; border-radius: 4px; }
        .state-unknown { background-color: #e2e3e5; color: #383d41; padding: 3px 8px; border-radius: 4px; }
        .no-apps { color: #666; font-style: italic; }
        .metadata { color: #666; margin-top: 20px; font-size: 0.9em; }
        .auto-refresh { text-align: right; color: #777; font-size: 0.8em; margin-top: 20px; }
        .container { max-width: 1000px; margin: 0 auto; }
      </style>
      <meta http-equiv="refresh" content="60"><!-- Auto refresh every 60 seconds -->
    </head>
    <body>
      <div class="container">
        <h1>Kamal Napper Dashboard</h1>
        
        <div class="status-container">
          <h2>Managed Applications</h2>
          
          #{status_info[:app_count] > 0 ? '' : '<p class="no-apps">No applications currently managed by Kamal Napper.</p>'}
          
          #{status_info[:app_count] > 0 ? '<table><tr><th>Application</th><th>Status</th><th>Time in Status</th></tr>' : ''}
          #{status_info[:apps].map do |hostname, app_info|
              "<tr>" +
              "<td>#{hostname}</td>" +
              "<td><span class=\"#{state_class(app_info[:current_state])}\">#{app_info[:current_state]}</span></td>" +
              "<td>#{format_duration(app_info[:time_in_state])}</td>" +
              "</tr>"
            end.join if status_info[:app_count] > 0}
          #{status_info[:app_count] > 0 ? '</table>' : ''}
        </div>
        
        <div class="metadata">
          <p>Poll interval: #{status_info[:poll_interval]}s</p>
          <p>Server time: #{Time.now}</p>
          <p class="auto-refresh">Page automatically refreshes every 60 seconds</p>
        </div>
      </div>
    </body>
    </html>
  HTML
end

# Set up signal handling
trap('INT') { server.shutdown }

# Start the server
puts "Starting Kamal Napper Web UI on port 80..."
server.start