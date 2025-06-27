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
ruby bin/kamal-napper start --daemon > /tmp/daemon.log 2>&1 &
daemon_pid=$!

# Wait longer for daemon to initialize and check if it's still running
sleep 10

# Check if daemon process is still alive
if kill -0 $daemon_pid 2>/dev/null; then
    echo "Daemon process is still running (PID: $daemon_pid)"
    
    # Verify daemon is responding to status checks
    if ruby bin/kamal-napper status > /dev/null 2>&1; then
        echo "Daemon is running successfully and responding to status checks"
    else
        echo "WARNING: Daemon process exists but not responding to status checks"
        echo "Daemon logs:"
        cat /tmp/daemon.log
    fi
else
    echo "ERROR: Daemon process has crashed"
    echo "Daemon logs:"
    cat /tmp/daemon.log
    echo "Continuing with web UI anyway..."
fi

# Start the web UI in the foreground (this keeps the container running)
echo "Starting web UI on port 80..."
exec ruby web_ui.rb