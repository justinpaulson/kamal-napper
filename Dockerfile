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

# Install runtime dependencies and build tools
RUN apt-get update && apt-get install -y \
    curl \
    procps \
    build-essential \
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

# We just need webrick for the simple web UI
RUN gem install webrick --no-document

# Copy our web UI app
COPY web_ui.rb /app/web_ui.rb
RUN chmod +x /app/web_ui.rb

# Run the web UI
CMD ["/usr/bin/env", "ruby", "/app/web_ui.rb"]
