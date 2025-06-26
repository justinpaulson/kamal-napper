# frozen_string_literal: true

require 'set'

module KamalNapper
  # Main daemon loop that monitors apps and manages their lifecycle
  class Supervisor
    class SupervisorError < StandardError; end

    def initialize(logger: nil, config: nil)
      @logger = logger || Logger.new
      @config = config || ConfigLoader.new
      @request_detector = RequestDetector.new(logger: @logger, config: @config)
      @health_checker = HealthChecker.new(logger: @logger, config: @config)
      @state_persistence = StatePersistence.new(logger: @logger, config: @config)
      @runner = Runner.new(logger: @logger, config: @config)

      @app_states = {}
      @running = false
      @poll_interval = @config.get('poll_interval') || 10
      @shutdown_requested = false

      # Load existing states on startup
      load_persisted_states
    end

    # Start the supervisor daemon
    def start
      if @running
        @logger.warn("Supervisor is already running")
        return false
      end

      @logger.info("Starting Kamal Napper supervisor")
      @running = true
      @shutdown_requested = false

      begin
        setup_signal_handlers
        main_loop
      rescue Interrupt
        @logger.info("Received interrupt signal, shutting down gracefully")
      rescue StandardError => e
        @logger.error("Supervisor error: #{e.message}")
        @logger.error(e.backtrace.join("\n")) if @logger.respond_to?(:debug)
        raise SupervisorError, "Supervisor failed: #{e.message}"
      ensure
        shutdown
      end
    end

    # Stop the supervisor daemon
    def stop
      @logger.info("Stopping supervisor")
      @shutdown_requested = true
    end

    # Get status of all managed apps
    def status
      {
        running: @running,
        app_count: @app_states.size,
        poll_interval: @poll_interval,
        apps: @app_states.transform_values(&:state_summary)
      }
    end

    # Stop all managed apps
    def stop_all_apps
      @logger.info("Stopping all managed apps")

      stopped_count = 0
      @app_states.each do |hostname, app_state|
        if app_state.active?
          begin
            stop_app(hostname)
            stopped_count += 1
          rescue StandardError => e
            @logger.error("Failed to stop #{hostname}: #{e.message}")
          end
        end
      end

      @logger.info("Stopped #{stopped_count} apps")
      stopped_count
    end

    # Wake up a specific app (start it immediately)
    def wake_app(hostname)
      @logger.info("Waking up app: #{hostname}")

      app_state = ensure_app_state(hostname)

      if app_state.current_state == :stopped
        start_app(hostname)
        true
      else
        @logger.info("#{hostname} is already in state: #{app_state.current_state}")
        false
      end
    end

    # Add a new app to be managed
    def add_app(hostname)
      unless @app_states.key?(hostname)
        @app_states[hostname] = AppState.new(hostname, logger: @logger, config: @config)
        @logger.info("Added app to supervision: #{hostname}")
        persist_states
      end
    end

    # Remove an app from management
    def remove_app(hostname)
      if @app_states.key?(hostname)
        app_state = @app_states[hostname]

        # Stop the app if it's running
        if app_state.active?
          stop_app(hostname)
        end

        @app_states.delete(hostname)
        @state_persistence.remove_app_state(hostname)
        @logger.info("Removed app from supervision: #{hostname}")
        true
      else
        false
      end
    end

    private

    def main_loop
      @logger.info("Supervisor main loop started (poll interval: #{@poll_interval}s)")

      while @running && !@shutdown_requested
        begin
          supervision_cycle
          persist_states
          sleep(@poll_interval)
        rescue StandardError => e
          @logger.error("Error in supervision cycle: #{e.message}")
          # Continue running despite errors
          sleep(@poll_interval)
        end
      end

      @logger.info("Supervisor main loop ended")
    end

    def supervision_cycle
      discover_new_apps

      @app_states.each do |hostname, app_state|
        begin
          manage_app_lifecycle(hostname, app_state)
        rescue StandardError => e
          @logger.error("Error managing #{hostname}: #{e.message}")
          # Reset app state on persistent errors
          app_state.reset!
        end
      end
    end

    def discover_new_apps
      # Get hostnames from request detector (kamal-proxy logs)
      detected_hostnames = @request_detector.detected_hostnames

      # Get apps from Kamal auto-discovery
      discovered_apps = @runner.discover_kamal_apps

      # Combine both sources
      all_hostnames = Set.new(detected_hostnames)
      discovered_apps.each_key { |hostname| all_hostnames.add(hostname) }

      # Ensure app states exist for all discovered apps
      all_hostnames.each do |hostname|
        ensure_app_state(hostname)
      end

      @logger.debug("Total apps being managed: #{@app_states.size}")
    end

    def manage_app_lifecycle(hostname, app_state)
      case app_state.current_state
      when :stopped
        handle_stopped_app(hostname, app_state)
      when :starting
        handle_starting_app(hostname, app_state)
      when :running
        handle_running_app(hostname, app_state)
      when :idle
        handle_idle_app(hostname, app_state)
      when :stopping
        handle_stopping_app(hostname, app_state)
      end
    end

    def handle_stopped_app(hostname, app_state)
      if app_state.should_start?(@request_detector)
        start_app(hostname)
      end
    end

    def handle_starting_app(hostname, app_state)
      if app_state.startup_timed_out?
        @logger.warn("#{hostname}: Startup timed out, resetting to stopped")
        app_state.force_transition_to(:stopped, reason: 'startup_timeout')
      elsif @health_checker.healthy?(hostname)
        app_state.transition_to(:running)
      end
    end

    def handle_running_app(hostname, app_state)
      if @request_detector.recent_requests?(hostname)
        # App is still receiving requests, keep it running
        @logger.debug("#{hostname}: Still receiving requests, staying running")
      else
        # No recent requests, transition to idle
        app_state.transition_to(:idle)
      end
    end

    def handle_idle_app(hostname, app_state)
      if @request_detector.recent_requests?(hostname)
        # New requests arrived, back to running
        app_state.transition_to(:running)
      elsif app_state.should_stop?
        # Been idle too long, stop the app
        stop_app(hostname)
      end
    end

    def handle_stopping_app(hostname, app_state)
      # Check if app has actually stopped
      unless @health_checker.healthy?(hostname)
        app_state.transition_to(:stopped)
      else
        # If still healthy after some time, force stop
        if app_state.time_in_current_state > 30 # 30 seconds timeout
          @logger.warn("#{hostname}: Force stopping after timeout")
          force_stop_app(hostname)
          app_state.force_transition_to(:stopped, reason: 'force_stop')
        end
      end
    end

    def start_app(hostname)
      app_state = @app_states[hostname]

      @logger.info("#{hostname}: Starting app")
      app_state.transition_to(:starting)

      begin
        @runner.start
        @logger.info("#{hostname}: Start command executed successfully")
      rescue Runner::CommandError => e
        @logger.error("#{hostname}: Failed to start: #{e.message}")
        app_state.force_transition_to(:stopped, reason: 'start_failed')
      end
    end

    def stop_app(hostname)
      app_state = @app_states[hostname]

      @logger.info("#{hostname}: Stopping app")
      app_state.transition_to(:stopping)

      begin
        @runner.stop
        @logger.info("#{hostname}: Stop command executed successfully")
      rescue Runner::CommandError => e
        @logger.error("#{hostname}: Failed to stop gracefully: #{e.message}")
        force_stop_app(hostname)
        app_state.force_transition_to(:stopped, reason: 'stop_failed')
      end
    end

    def force_stop_app(hostname)
      @logger.warn("#{hostname}: Force stopping app")

      begin
        # Try maintenance mode to stop traffic
        @runner.maintenance(enable: true)
        sleep(2)
        @runner.stop
        @runner.maintenance(enable: false)
      rescue StandardError => e
        @logger.error("#{hostname}: Force stop failed: #{e.message}")
      end
    end

    def ensure_app_state(hostname)
      unless @app_states.key?(hostname)
        @app_states[hostname] = AppState.new(hostname, logger: @logger, config: @config)
        @logger.debug("Created new app state for: #{hostname}")
      end

      @app_states[hostname]
    end

    def load_persisted_states
      @logger.info("Loading persisted app states")

      begin
        persisted_states = @state_persistence.load_states
        @app_states.merge!(persisted_states)
        @logger.info("Loaded #{persisted_states.size} persisted app states")
      rescue StatePersistence::PersistenceError => e
        @logger.error("Failed to load persisted states: #{e.message}")
        @logger.info("Starting with empty state")
      end
    end

    def persist_states
      begin
        @state_persistence.save_states(@app_states)
      rescue StatePersistence::PersistenceError => e
        @logger.error("Failed to persist states: #{e.message}")
      end
    end

    def setup_signal_handlers
      # Handle SIGTERM and SIGINT gracefully
      %w[TERM INT].each do |signal|
        Signal.trap(signal) do
          @logger.info("Received SIG#{signal}, initiating graceful shutdown")
          @shutdown_requested = true
        end
      end

      # Handle SIGUSR1 for status dump
      Signal.trap('USR1') do
        @logger.info("Status dump requested via SIGUSR1")
        log_status_dump
      end
    end

    def log_status_dump
      status_info = status
      @logger.info("=== Supervisor Status ===")
      @logger.info("Running: #{status_info[:running]}")
      @logger.info("Apps managed: #{status_info[:app_count]}")
      @logger.info("Poll interval: #{status_info[:poll_interval]}s")

      status_info[:apps].each do |hostname, app_info|
        @logger.info("#{hostname}: #{app_info[:current_state]} (#{app_info[:time_in_state]}s)")
      end
      @logger.info("=== End Status ===")
    end

    def shutdown
      @logger.info("Supervisor shutting down")
      @running = false

      # Persist final state
      persist_states

      @logger.info("Supervisor shutdown complete")
    end
  end
end
