FROM ruby:3.3-alpine

# Install dependencies
RUN apk add --no-cache \
    build-base \
    tzdata \
    git \
    curl \
    wget

# Install Docker CLI for container discovery
RUN apk add --no-cache docker-cli

# Set working directory
WORKDIR /app

# Copy application files
COPY . /app/

# Make startup script executable
RUN chmod +x /app/start.sh

# Bundle and install the application
RUN bundle install

# Configure health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O- http://localhost:80/health || exit 1

EXPOSE 80

# Run the startup script that starts both daemon and web UI
CMD ["/app/start.sh"]