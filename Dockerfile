# Multi-stage build for production-ready Kamal Napper
FROM ruby:3.3-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy gem files first for better caching
COPY Gemfile Gemfile.lock kamal-napper.gemspec ./
COPY lib/kamal_napper/version.rb ./lib/kamal_napper/

# Install gems
RUN bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle config set --local path '/usr/local/bundle' && \
    bundle install --jobs 4 --retry 3 && \
    bundle exec gem list && \
    echo "Verifying thor gem installation:" && \
    bundle exec gem list thor

# Production stage
FROM ruby:3.3-slim as production

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user
RUN groupadd -r kamal && useradd -r -g kamal -d /app -s /bin/bash kamal

# Set working directory
WORKDIR /app

# Copy gems from builder stage
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Copy application code
COPY --chown=kamal:kamal . .

# Create necessary directories with proper permissions - use 777 for container compatibility
RUN mkdir -p /var/lib/kamal-napper /var/log/kamal-napper && \
    chmod -R 777 /var/lib/kamal-napper /var/log/kamal-napper && \
    chown -R kamal:kamal /var/lib/kamal-napper /var/log/kamal-napper /app

# Switch to non-root user
USER kamal

# Set environment variables
ENV RACK_ENV=production
ENV BUNDLE_DEPLOYMENT=true
ENV BUNDLE_WITHOUT=development:test
ENV BUNDLE_PATH=/usr/local/bundle

# Expose port 80 for Kamal health checks
EXPOSE 80

# Simple health check with longer start period
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -f http://localhost/health || exit 1

# Install webrick first, then run a simple health check server
RUN gem install webrick --no-document

# Add Sinatra for minimal web UI
RUN gem install sinatra webrick json --no-document

# Create simple web UI app
RUN echo '#!/usr/bin/env ruby

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
' > /app/web_ui.rb && chmod +x /app/web_ui.rb

# Run the web UI
CMD ["/usr/bin/env", "ruby", "/app/web_ui.rb"]
