#!/bin/sh

# Kamal Napper startup script
# Runs both the web UI and the monitoring daemon

set -e

echo "Starting Kamal Napper..."

# Ensure state directory exists
mkdir -p /var/lib/kamal-napper

# Change to app directory
cd /app

# Start the monitoring daemon in the background
echo "Starting Kamal Napper daemon..."
ruby bin/kamal-napper start --daemon

# Wait a moment for daemon to initialize
sleep 5

# Verify daemon is running
if ruby bin/kamal-napper status > /dev/null 2>&1; then
    echo "Daemon is running successfully"
else
    echo "WARNING: Daemon may not be running properly, but continuing with web UI"
fi

# Start the web UI in the foreground (this keeps the container running)
echo "Starting web UI on port 80..."
exec ruby web_ui.rb