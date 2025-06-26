FROM ruby:3.3-alpine

# Install dependencies
RUN apk add --no-cache \
    build-base \
    tzdata \
    git \
    curl \
    wget

# Set working directory
WORKDIR /app

# Copy application files
COPY . /app/

# Bundle and install the application
RUN bundle install

# Configure health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O- http://localhost:80/health || exit 1

EXPOSE 80

# Run the web UI
CMD ["ruby", "web_ui.rb"]