#!/usr/bin/env ruby

require "webrick"

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

# Default page with basic info
server.mount_proc("/") do |req, res|
  res.status = 200
  res['Content-Type'] = 'text/html'
  res.body = <<-HTML
    <!DOCTYPE html>
    <html>
    <head>
      <title>Kamal Napper</title>
      <style>
        body { font-family: sans-serif; margin: 20px; }
        h1 { color: #333; }
      </style>
    </head>
    <body>
      <h1>Kamal Napper is Running!</h1>
      <p>This is a simple service that manages your Kamal apps by turning them on and off.</p>
      <p>Server time: #{Time.now}</p>
    </body>
    </html>
  HTML
end

# Set up signal handling
trap('INT') { server.shutdown }

# Start the server
puts "Starting Kamal Napper Web UI on port 80..."
server.start