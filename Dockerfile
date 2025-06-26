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

# Create necessary directories with proper permissions
RUN mkdir -p /var/lib/kamal-napper /var/log/kamal-napper && \
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

# Health check configuration for Kamal compatibility
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -f http://localhost/health || exit 1

# Run in foreground mode for better compatibility with Kamal
CMD ["bundle", "exec", "/app/bin/kamal-napper", "start"]
