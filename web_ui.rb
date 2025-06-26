#!/usr/bin/env ruby

require "sinatra"
require "json"

set :bind, "0.0.0.0"
set :port, 80

# Apps status (simple in-memory store for demo)
$apps = {
  "app1.example.com" => { :status => "running", :last_active => Time.now },
  "app2.example.com" => { :status => "sleeping", :last_active => Time.now - 3600 }
}

# Health check endpoint
get "/health" do
  content_type :json
  { :status => "ok", :service => "kamal-napper", :timestamp => Time.now }.to_json
end

# Required for Kamal proxy
get "/up" do
  "OK"
end

# Main UI page
get "/" do
  html = <<-HTML
    <!DOCTYPE html>
    <html>
      <head>
        <title>Kamal Napper</title>
        <style>
          body { font-family: sans-serif; margin: 20px; }
          h1 { color: #333; }
          table { border-collapse: collapse; width: 100%; }
          th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
          th { background-color: #f2f2f2; }
          .running { color: green; }
          .sleeping { color: orange; }
        </style>
      </head>
      <body>
        <h1>Kamal Napper Dashboard</h1>
        <p>Manage your apps that are controlled by Kamal Napper</p>
        <table>
          <tr>
            <th>Hostname</th>
            <th>Status</th>
            <th>Last Active</th>
            <th>Actions</th>
          </tr>
          #{$apps.map { |hostname, data|
            "<tr>
              <td>#{hostname}</td>
              <td class=\"#{data[:status]}\">#{data[:status]}</td>
              <td>#{data[:last_active].strftime("%Y-%m-%d %H:%M")}</td>
              <td>
                <a href=\"/wake/#{hostname}\">Wake</a> |
                <a href=\"/sleep/#{hostname}\">Sleep</a>
              </td>
            </tr>"
          }.join}
        </table>
      </body>
    </html>
  HTML
  html
end

# Wake an app
get "/wake/:hostname" do
  hostname = params[:hostname]
  if $apps[hostname]
    $apps[hostname][:status] = "running"
    $apps[hostname][:last_active] = Time.now
    redirect "/"
  else
    status 404
    "App not found"
  end
end

# Put an app to sleep
get "/sleep/:hostname" do
  hostname = params[:hostname]
  if $apps[hostname]
    $apps[hostname][:status] = "sleeping"
    redirect "/"
  else
    status 404
    "App not found"
  end
end

# API endpoints
get "/api/apps" do
  content_type :json
  $apps.to_json
end

puts "Starting Kamal Napper Web UI on port 80..."