Kamal Napper: Rails Idle App Supervisor

📌 Goal

Build a daemon process (Ruby gem or containerized service) that:
	1.	Runs alongside other Rails apps deployed via Kamal 2 on a single EC2 instance.
	2.	Tracks incoming requests per hostname (via kamal-proxy access logs or HTTP pings).
	3.	Automatically stops Rails app containers after a period of inactivity.
	4.	Automatically starts containers when new requests arrive.
	5.	Uses Kamal’s built-in maintenance mode to serve a spinner page while apps are starting.

The daemon itself is deployed via Kamal and fully self-contained.

⸻

🧱 System Components

1. Supervisor Daemon (kamal-napper)
	•	Long-running process monitoring traffic/activity per app
	•	Stores app state (running, idle, booting)
	•	Executes Kamal commands
	•	Writes logs for observability

2. Idle Tracker
	•	Tracks timestamps of most recent requests per domain/app

3. Request Detector
	•	Parses kamal-proxy logs or uses alternate request-tracking strategies

4. Kamal Interface
	•	Runs Kamal or Docker commands as needed:
	•	kamal app maintenance
	•	kamal app stop
	•	kamal app start
	•	kamal app live

5. Maintenance Page
	•	Custom 503 page with spinner/auto-refresh

⸻

⚙️ Config File

idle_timeout: 900  # seconds
poll_interval: 10  # seconds
apps:
  app1:
    domain: app1.example.com
    service: app1
  app2:
    domain: app2.example.com
    service: app2
log_path: /var/log/kamal-proxy/access.log


⸻

🧠 Application Logic

App States
	•	:running
	•	:idle
	•	:stopped
	•	:starting

Supervisor Loop (pseudo-code)

loop do
  apps.each do |app|
    update_last_seen(app)

    if app.status == :running && app.idle_for > idle_timeout
      enable_maintenance_mode(app)
      stop_container(app)
      app.status = :stopped

    elsif app.status == :stopped && request_seen_while_stopped(app)
      start_container(app)
      app.status = :starting

    elsif app.status == :starting && app_responding(app)
      disable_maintenance_mode(app)
      app.status = :running
    end
  end
  sleep poll_interval
end


⸻

🧪 Kamal Command Integration

Action	Command
Enable maintenance	kamal app maintenance APP
Stop app	kamal app stop APP
Start app	kamal app start APP
Disable maintenance	kamal app live APP


⸻

📁 Project Structure

kamal-napper/
├── bin/
│   └── kamal-napper               # Entry CLI
├── lib/kamal_napper/
│   ├── cli.rb                    # CLI command interface
│   ├── supervisor.rb             # Main loop
│   ├── app_state.rb              # Tracks app lifecycle
│   ├── runner.rb                 # Kamal/Docker interface
│   ├── log_watcher.rb            # Tails proxy logs
│   ├── config_loader.rb          # Loads YAML config
│   └── logger.rb                 # Logging utility
├── templates/
│   └── 503.html                  # Spinner page
├── config/
│   └── kamal_napper.yml
├── Dockerfile
├── kamal.yml                     # Kamal deploy config for napper
└── kamal-napper.gemspec


⸻

🐳 Dockerfile (example)

FROM ruby:3.3

WORKDIR /app

COPY . .

RUN bundle install

CMD ["bin/kamal-napper", "start"]


⸻

🧾 Kamal Config (for the napper itself)

service: idle-manager
image: your-docker-repo/kamal-napper
servers:
  - deploy@your-ec2-instance
roles:
  - idle
env:
  IDLE_TIMEOUT: 900
  LOG_PATH: /var/log/kamal-proxy/access.log


⸻

💡 Spinner Maintenance Page (503.html)

<html>
  <head>
    <meta http-equiv="refresh" content="3" />
    <style>
      body { font-family: sans-serif; text-align: center; padding-top: 100px; }
    </style>
  </head>
  <body>
    <h1>⏳ Starting your app...</h1>
    <p>Please wait while we wake things up. This usually takes a few seconds.</p>
  </body>
</html>


⸻

✅ Benefits
	•	Fully compatible with Kamal 2
	•	Keeps multiple apps dormant until needed
	•	Minimal cost and resource usage
	•	End-user sees smooth spinner/refresh experience

⸻

🧪 Testing Plan
	•	Unit tests for:
	•	App state transitions
	•	Log parsing
	•	Kamal/Docker commands
	•	Integration tests with mock apps and proxy logs
	•	Manual test via real Rails app and live container transitions

⸻

🔧 Optional Enhancements
	•	Add Prometheus export or status API
	•	kamal-napper status CLI
	•	Watchdog restart logic if container fails to come back
	•	Schedule-aware wake/sleep behavior (e.g., awake during business hours)

⸻

🧠 Deliverables
	•	Ruby gem: kamal-napper
	•	Dockerfile
	•	Kamal config to deploy it
	•	Sample spinner page
	•	CLI commands and system logs
	•	README
