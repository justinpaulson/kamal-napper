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
      @logger.info("Getting status, current app count: #{@app_states.size}")
      @logger.info("App keys: #{@app_states.keys.inspect}")
      
      status_info = {
        running: @running,
        app_count: @app_states.size,
        poll_interval: @poll_interval,
        apps: @app_states.transform_values(&:state_summary)
      }
      
      @logger.debug("Status info: #{status_info.inspect[0..100]}...")
      status_info
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
          # Validate state sync periodically
          validate_app_state_sync(hostname, app_state)
          
          manage_app_lifecycle(hostname, app_state)
        rescue StandardError => e
          @logger.error("Error managing #{hostname}: #{e.message}")
          # Reset app state on persistent errors
          app_state.reset!
        end
      end
    end

    def validate_app_state_sync(hostname, app_state)
      # Only validate every 5th cycle to avoid too much overhead
      return if rand(5) != 0
      
      actual_healthy = @health_checker.healthy?(hostname)
      expected_healthy = app_state.active?
      
      if actual_healthy != expected_healthy
        @logger.warn("#{hostname}: State sync mismatch - internal: #{app_state.current_state}, actual: #{actual_healthy ? 'healthy' : 'unhealthy'}")
        
        if actual_healthy && !expected_healthy
          @logger.info("#{hostname}: Container is running but state is #{app_state.current_state}, correcting to running")
          app_state.force_transition_to(:running, reason: 'state_sync_correction')
        elsif !actual_healthy && expected_healthy
          @logger.info("#{hostname}: Container is stopped but state is #{app_state.current_state}, correcting to stopped")
          app_state.force_transition_to(:stopped, reason: 'state_sync_correction')
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

      # Filter out invalid hostnames
      valid_hostnames = all_hostnames.select { |hostname| valid_hostname?(hostname) }

      # Ensure app states exist for all discovered apps
      valid_hostnames.each do |hostname|
        ensure_app_state(hostname)
      end

      @logger.debug("Total apps being managed: #{@app_states.size}")
    end

    def valid_hostname?(hostname)
      return false if hostname.nil? || hostname.empty?
      return false if hostname.match?(/^\d+\.\d+\.\d+\.\d+/) # Skip IP addresses
      return false if hostname == 'localhost'
      return false if hostname.include?(':') # Skip hostname:port formats
      
      # Skip kamal-napper itself to prevent self-monitoring
      if self_hostname?(hostname)
        @logger.debug("Skipping self-hostname: #{hostname}")
        return false
      end
      
      # Must contain at least one dot and be a reasonable length
      hostname.include?('.') && hostname.length > 3 && hostname.length < 100
    end

    def self_hostname?(hostname)
      # Check configured hostname from deploy.yml
      configured_hostname = @config.own_hostname
      return true if configured_hostname && hostname == configured_hostname
      
      # Fallback to pattern matching for backwards compatibility
      hostname.include?('kamal-napper') || hostname.include?('naptime')
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
        # Disable maintenance mode on timeout
        begin
          @runner.maintenance(enable: false)
          @logger.info("#{hostname}: Disabled maintenance mode after startup timeout")
        rescue StandardError => e
          @logger.warn("#{hostname}: Failed to disable maintenance mode after timeout: #{e.message}")
        end
        app_state.force_transition_to(:stopped, reason: 'startup_timeout')
      elsif @health_checker.healthy?(hostname)
        # Container is healthy, disable maintenance mode and transition to running
        begin
          @runner.maintenance(enable: false)
          @logger.info("#{hostname}: Disabled maintenance mode, app is now healthy")
        rescue StandardError => e
          @logger.warn("#{hostname}: Failed to disable maintenance mode: #{e.message}")
        end
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

      # Enable maintenance mode to show spinner page instead of 502 errors
      begin
        @runner.maintenance(enable: true)
        @logger.info("#{hostname}: Enabled maintenance mode during startup")
      rescue StandardError => e
        @logger.warn("#{hostname}: Failed to enable maintenance mode: #{e.message}")
      end

      begin
        success = @runner.start_app_container(hostname)
        if success
          @logger.info("#{hostname}: Start command executed successfully")
        else
          @logger.error("#{hostname}: Failed to start container")
          # Disable maintenance mode on failure
          begin
            @runner.maintenance(enable: false)
          rescue StandardError => e
            @logger.warn("#{hostname}: Failed to disable maintenance mode after start failure: #{e.message}")
          end
          app_state.force_transition_to(:stopped, reason: 'start_failed')
        end
      rescue Runner::CommandError => e
        @logger.error("#{hostname}: Failed to start: #{e.message}")
        # Disable maintenance mode on failure
        begin
          @runner.maintenance(enable: false)
        rescue StandardError => e
          @logger.warn("#{hostname}: Failed to disable maintenance mode after start failure: #{e.message}")
        end
        app_state.force_transition_to(:stopped, reason: 'start_failed')
      end
    end

    def stop_app(hostname)
      app_state = @app_states[hostname]

      @logger.info("#{hostname}: Stopping app")
      app_state.transition_to(:stopping)

      begin
        success = @runner.stop_app_container(hostname)
        if success
          @logger.info("#{hostname}: Stop command executed successfully")
        else
          @logger.error("#{hostname}: Failed to stop container")
          force_stop_app(hostname)
          app_state.force_transition_to(:stopped, reason: 'stop_failed')
        end
      rescue Runner::CommandError => e
        @logger.error("#{hostname}: Failed to stop gracefully: #{e.message}")
        force_stop_app(hostname)
        app_state.force_transition_to(:stopped, reason: 'stop_failed')
      end
    end

    def force_stop_app(hostname)
      @logger.warn("#{hostname}: Force stopping app")

      begin
        # Force stop the container directly
        service_name = hostname.split('.').first
        result = `docker ps --filter 'label=service=#{service_name}' --format '{{.Names}}'`.strip
        
        if !result.empty?
          container_name = result.lines.first&.strip
          if container_name
            @logger.info("#{hostname}: Force killing container #{container_name}")
            `docker kill #{container_name}`
          end
        end
      rescue StandardError => e
        @logger.error("#{hostname}: Force stop failed: #{e.message}")
      end
    end

    def ensure_app_state(hostname)
      unless @app_states.key?(hostname)
        @app_states[hostname] = AppState.new(hostname, logger: @logger, config: @config)
        @logger.debug("Created new app state for: #{hostname}")
        
        # Initialize state based on actual container status
        initialize_app_state(hostname)
      end

      @app_states[hostname]
    end

    def initialize_app_state(hostname)
      app_state = @app_states[hostname]
      
      # Check if container is actually running
      if @health_checker.healthy?(hostname)
        @logger.info("#{hostname}: Container is running, initializing to running state")
        app_state.force_transition_to(:running, reason: 'initial_state_sync')
      else
        @logger.info("#{hostname}: Container is not healthy, keeping in stopped state")
      end
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
