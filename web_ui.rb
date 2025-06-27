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

# API endpoint to control app state (POST)
server.mount_proc("/api/control") do |req, res|
  if req.request_method != 'POST'
    res.status = 405
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate({error: "Method not allowed. Use POST."})
    next
  end
  
  begin
    # Parse hostname and action from request body or query params
    hostname = nil
    action = nil
    
    if req.content_length && req.content_length > 0
      request_body = req.body
      if request_body
        begin
          data = JSON.parse(request_body)
          hostname = data['hostname']
          action = data['action']
        rescue JSON::ParserError
          # Try form data
          hostname = req.query['hostname']
          action = req.query['action']
        end
      end
    else
      hostname = req.query['hostname']
      action = req.query['action']
    end
    
    unless hostname
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate({error: "Missing hostname parameter"})
      next
    end
    
    unless action && ['wake', 'sleep'].include?(action)
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate({error: "Missing or invalid action parameter. Use 'wake' or 'sleep'."})
      next
    end
    
    supervisor = get_supervisor
    
    if action == 'wake'
      success = supervisor.wake_app(hostname)
      message = success ? "Wake up initiated for #{hostname}" : "App #{hostname} is already active or not found"
    else # action == 'sleep'
      # Find the app state and stop it if it's active
      status_info = supervisor.status
      app_info = status_info[:apps][hostname]
      
      if app_info && [:running, :idle].include?(app_info[:current_state])
        # Stop the app by calling the supervisor's internal method
        begin
          supervisor.send(:stop_app, hostname)
          success = true
          message = "Sleep initiated for #{hostname}"
        rescue StandardError => e
          success = false
          message = "Failed to put #{hostname} to sleep: #{e.message}"
        end
      else
        success = false
        message = "App #{hostname} is not currently active or not found"
      end
    end
    
    res.status = success ? 200 : 400
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate({
      success: success,
      hostname: hostname,
      action: action,
      message: message,
      timestamp: Time.now.iso8601
    })
  rescue StandardError => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate({
      error: "Internal server error: #{e.message}",
      timestamp: Time.now.iso8601
    })
  end
end

# API endpoint to manually wake up an app (POST) - kept for backward compatibility
server.mount_proc("/api/wake") do |req, res|
  if req.request_method != 'POST'
    res.status = 405
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate({error: "Method not allowed. Use POST."})
    next
  end
  
  begin
    # Parse hostname from request body or query params
    hostname = nil
    if req.content_length && req.content_length > 0
      request_body = req.body
      if request_body
        begin
          data = JSON.parse(request_body)
          hostname = data['hostname']
        rescue JSON::ParserError
          # Try form data
          hostname = req.query['hostname']
        end
      end
    else
      hostname = req.query['hostname']
    end
    
    unless hostname
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate({error: "Missing hostname parameter"})
      next
    end
    
    supervisor = get_supervisor
    success = supervisor.wake_app(hostname)
    
    res.status = success ? 200 : 400
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate({
      success: success,
      hostname: hostname,
      message: success ? "Wake up initiated for #{hostname}" : "App #{hostname} is already active or not found",
      timestamp: Time.now.iso8601
    })
  rescue StandardError => e
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate({
      error: "Internal server error: #{e.message}",
      timestamp: Time.now.iso8601
    })
  end
end

# Create supervisor instance to access app states
def get_supervisor
  @logger ||= KamalNapper::Logger.new
  @config ||= KamalNapper::ConfigLoader.new
  KamalNapper::Supervisor.new(logger: @logger, config: @config)
end

# Get combined app state (actual state + tracked state + last activity)
def get_app_state(hostname, app_info)
  service_name = hostname.split('.').first
  tracked_state = app_info[:current_state]
  
  # Get actual container state from Docker
  result = `docker ps --filter "name=#{service_name}-web" --format "{{.Status}}" 2>/dev/null`.strip
  container_running = !result.empty?
  container_status = result.empty? ? 'Not running' : result
  
  # Get last activity from request detector
  request_detector = KamalNapper::RequestDetector.new(logger: @logger, config: @config)
  last_activity = request_detector.last_request_time(hostname)
  activity_info = if last_activity
    time_ago = Time.now - last_activity
    if time_ago < 60
      "#{time_ago.round}s ago"
    elsif time_ago < 3600
      "#{(time_ago / 60).round}m ago"
    elsif time_ago < 86400
      "#{(time_ago / 3600).round}h ago"
    else
      "#{(time_ago / 86400).round}d ago"
    end
  else
    "No activity detected"
  end
  
  # Check if we should show "waking up" state
  # This happens when the container is stopped but we detected recent activity
  request_detector = KamalNapper::RequestDetector.new(logger: @logger, config: @config)
  has_recent_activity = request_detector.recent_requests?(hostname, within_seconds: 30)
  
  # Determine the real state based on container state and tracked state
  if container_running
    if tracked_state == :starting
      { state: 'Starting', css_class: 'state-starting', description: "Container is starting up", status: container_status, activity: activity_info }
    elsif tracked_state == :stopping
      { state: 'Stopping', css_class: 'state-stopping', description: "Container is shutting down", status: container_status, activity: activity_info }
    elsif tracked_state == :idle
      { state: 'Idle', css_class: 'state-idle', description: "Running but idle", status: container_status, activity: "Last active #{activity_info}" }
    else
      { state: 'Running', css_class: 'state-running', description: "Container is active", status: container_status, activity: "Last active #{activity_info}" }
    end
  else
    # Container is not running - check if it should be waking up
    if has_recent_activity && tracked_state == :stopped
      { state: 'Waking Up', css_class: 'state-waking', description: "Application is waking up due to recent activity", status: "Starting container...", activity: "Activity detected, starting container" }
    else
      { state: 'Stopped', css_class: 'state-stopped', description: "Container is not running", status: container_status, activity: "Last active #{activity_info}" }
    end
  end
rescue StandardError => e
  { state: 'Unknown', css_class: 'state-unknown', description: "Error: #{e.message}", status: 'Error getting status', activity: 'Unknown' }
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

# Get appropriate refresh interval based on app states
def get_refresh_interval(status_info)
  # Check if any apps are in transitional states
  transitional_states = [:starting, :stopping]
  waking_states = status_info[:apps].any? do |hostname, app_info|
    # Check if app might be waking up
    app_state = get_app_state(hostname, app_info)
    app_state[:state] == 'Waking Up'
  end
  
  has_transitional = status_info[:apps].any? do |_, app_info|
    transitional_states.include?(app_info[:current_state])
  end
  
  if waking_states || has_transitional
    10  # Refresh every 10 seconds for active transitions
  else
    60  # Normal refresh every 60 seconds
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
        .state-waking { background-color: #ffeaa7; color: #d63031; padding: 3px 8px; border-radius: 4px; animation: pulse 2s infinite; }
        .state-unknown { background-color: #e2e3e5; color: #383d41; padding: 3px 8px; border-radius: 4px; }
        @keyframes pulse {
          0% { opacity: 1; }
          50% { opacity: 0.6; }
          100% { opacity: 1; }
        }
        .no-apps { color: #666; font-style: italic; }
        .metadata { color: #666; margin-top: 20px; font-size: 0.9em; }
        .auto-refresh { text-align: right; color: #777; font-size: 0.8em; margin-top: 20px; }
        .container { max-width: 1000px; margin: 0 auto; }
        
        /* Toggle switch styles */
        .toggle-container { display: flex; align-items: center; gap: 8px; }
        .toggle-switch { position: relative; display: inline-block; width: 50px; height: 24px; }
        .toggle-switch input { opacity: 0; width: 0; height: 0; }
        .toggle-slider { position: absolute; cursor: pointer; top: 0; left: 0; right: 0; bottom: 0; 
                        background-color: #ccc; transition: .4s; border-radius: 24px; }
        .toggle-slider:before { position: absolute; content: ""; height: 18px; width: 18px; left: 3px; bottom: 3px;
                               background-color: white; transition: .4s; border-radius: 50%; }
        input:checked + .toggle-slider { background-color: #4CAF50; }
        input:checked + .toggle-slider:before { transform: translateX(26px); }
        input:disabled + .toggle-slider { background-color: #ddd; cursor: not-allowed; }
        .toggle-label { font-size: 0.9em; color: #666; min-width: 60px; }
        .wake-button { background: #007bff; color: white; border: none; padding: 4px 8px; 
                      border-radius: 4px; cursor: pointer; font-size: 0.8em; }
        .wake-button:hover { background: #0056b3; }
        .wake-button:disabled { background: #ccc; cursor: not-allowed; }
        .action-feedback { font-size: 0.8em; color: #666; margin-left: 8px; }
      </style>
      <meta http-equiv="refresh" content="#{get_refresh_interval(status_info)}"><!-- Auto refresh interval based on app states -->
    </head>
    <body>
      <div class="container">
        <h1>Kamal Napper Dashboard</h1>
        
        <div class="status-container">
          <h2>Managed Applications</h2>
          
          #{status_info[:app_count] > 0 ? '' : '<p class="no-apps">No applications currently managed by Kamal Napper.</p>'}
          
          #{status_info[:app_count] > 0 ? '<table><tr><th>Application</th><th>State</th><th>Details</th><th>Container Status</th><th>Actions</th></tr>' : ''}
          #{status_info[:apps].map do |hostname, app_info|
              # Get display name - strip .local if present
              display_name = hostname.end_with?('.local') ? hostname.gsub('.local', '') : hostname
              # Get combined app state
              app_state = get_app_state(hostname, app_info)
              
              # Determine toggle state and enabled/disabled status
              is_checked = [:running, :idle, :starting].include?(app_info[:current_state]) || app_state[:state] == 'Waking Up'
              is_transitional = [:starting, :stopping].include?(app_info[:current_state]) || app_state[:state] == 'Waking Up'
              safe_hostname = hostname.gsub('.', '-')
              
              action_html = "<div class=\"toggle-container\">" +
                "<label class=\"toggle-switch\">" +
                "<input type=\"checkbox\" #{is_checked ? 'checked' : ''} #{is_transitional ? 'disabled' : ''} " +
                "onchange=\"toggleApp('#{hostname}', this)\" id=\"toggle-#{safe_hostname}\">" +
                "<span class=\"toggle-slider\"></span>" +
                "</label>" +
                "<span class=\"toggle-label\">#{is_checked ? 'On' : 'Off'}</span>" +
                "<span class=\"action-feedback\" id=\"feedback-#{safe_hostname}\"></span>" +
                "</div>"
              
              "<tr>" +
              "<td>#{display_name}</td>" +
              "<td><span class=\"#{app_state[:css_class]}\">#{app_state[:state]}</span></td>" +
              "<td>#{app_state[:description]}<br><small style=\"color: #666;\">#{app_state[:activity]}</small></td>" +
              "<td><small>#{app_state[:status]}</small></td>" +
              "<td>#{action_html}</td>" +
              "</tr>"
            end.join if status_info[:app_count] > 0}
          #{status_info[:app_count] > 0 ? '</table>' : ''}
        </div>
        
        <div class="metadata">
          <p>Poll interval: #{status_info[:poll_interval]}s</p>
          <p>Server time: #{Time.now}</p>
          <p class="auto-refresh">Page automatically refreshes every #{get_refresh_interval(status_info)} seconds</p>
        </div>
      </div>
      
      <script>
        async function toggleApp(hostname, toggleElement) {
          const safeHostname = hostname.replace(/\\./g, '-');
          const feedbackElement = document.getElementById('feedback-' + safeHostname);
          const labelElement = toggleElement.closest('.toggle-container').querySelector('.toggle-label');
          const originalChecked = !toggleElement.checked; // Store original state before change
          
          // Determine action based on toggle state
          const action = toggleElement.checked ? 'wake' : 'sleep';
          const actionText = action === 'wake' ? 'Waking up' : 'Putting to sleep';
          
          // Disable toggle and show loading state
          toggleElement.disabled = true;
          feedbackElement.textContent = actionText + '...';
          feedbackElement.style.color = '#007bff';
          labelElement.textContent = 'Processing...';
          
          try {
            const response = await fetch('/api/control', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
              },
              body: JSON.stringify({ 
                hostname: hostname,
                action: action
              })
            });
            
            const result = await response.json();
            
            if (response.ok && result.success) {
              feedbackElement.textContent = result.message + ' Refreshing in 3s...';
              feedbackElement.style.color = '#28a745';
              labelElement.textContent = toggleElement.checked ? 'On' : 'Off';
              
              // Refresh the page after 3 seconds to show updated state
              setTimeout(() => {
                window.location.reload();
              }, 3000);
            } else {
              feedbackElement.textContent = result.message || (action + ' failed');
              feedbackElement.style.color = '#dc3545';
              
              // Revert toggle state and re-enable after error
              setTimeout(() => {
                toggleElement.checked = originalChecked;
                toggleElement.disabled = false;
                labelElement.textContent = originalChecked ? 'On' : 'Off';
                feedbackElement.textContent = '';
              }, 3000);
            }
          } catch (error) {
            console.error('Toggle request failed:', error);
            feedbackElement.textContent = 'Network error occurred';
            feedbackElement.style.color = '#dc3545';
            
            // Revert toggle state and re-enable after error
            setTimeout(() => {
              toggleElement.checked = originalChecked;
              toggleElement.disabled = false;
              labelElement.textContent = originalChecked ? 'On' : 'Off';
              feedbackElement.textContent = '';
            }, 3000);
          }
        }
        
        // Legacy function for backward compatibility
        async function wakeApp(hostname, button) {
          const feedbackElement = document.getElementById('feedback-' + hostname.replace(/\\./g, '-'));
          const originalText = button.textContent;
          
          // Disable button and show loading state
          button.disabled = true;
          button.textContent = 'Waking...';
          feedbackElement.textContent = 'Initiating wake-up...';
          feedbackElement.style.color = '#007bff';
          
          try {
            const response = await fetch('/api/wake', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
              },
              body: JSON.stringify({ hostname: hostname })
            });
            
            const result = await response.json();
            
            if (response.ok && result.success) {
              feedbackElement.textContent = 'Wake-up initiated! Refreshing in 3s...';
              feedbackElement.style.color = '#28a745';
              
              // Refresh the page after 3 seconds to show updated state
              setTimeout(() => {
                window.location.reload();
              }, 3000);
            } else {
              feedbackElement.textContent = result.message || 'Wake-up failed';
              feedbackElement.style.color = '#dc3545';
              
              // Re-enable button after error
              setTimeout(() => {
                button.disabled = false;
                button.textContent = originalText;
                feedbackElement.textContent = '';
              }, 3000);
            }
          } catch (error) {
            console.error('Wake-up request failed:', error);
            feedbackElement.textContent = 'Network error occurred';
            feedbackElement.style.color = '#dc3545';
            
            // Re-enable button after error
            setTimeout(() => {
              button.disabled = false;
              button.textContent = originalText;
              feedbackElement.textContent = '';
            }, 3000);
          }
        }
        
        // Add a small indicator when the page is about to refresh
        let refreshInterval = #{get_refresh_interval(status_info)};
        if (refreshInterval <= 15) {
          // Only show countdown for fast refresh intervals
          let timeLeft = refreshInterval;
          const refreshTimer = setInterval(() => {
            timeLeft--;
            if (timeLeft <= 5 && timeLeft > 0) {
              const refreshElement = document.querySelector('.auto-refresh');
              if (refreshElement) {
                refreshElement.textContent = `Page automatically refreshes in ${timeLeft} seconds`;
              }
            } else if (timeLeft <= 0) {
              clearInterval(refreshTimer);
            }
          }, 1000);
        }
      </script>
    </body>
    </html>
  HTML
end

# Set up signal handling
trap('INT') { server.shutdown }

# Start the server
puts "Starting Kamal Napper Web UI on port 80..."
server.start