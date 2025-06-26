# frozen_string_literal: true

module KamalNapper
  # Application state management with state machine and transition tracking
  class AppState
    class StateError < Error; end

    # Valid application states
    STATES = %i[stopped idle running starting stopping].freeze

    # Valid state transitions
    TRANSITIONS = {
      stopped: %i[starting],
      starting: %i[running stopped],
      running: %i[idle stopping],
      idle: %i[starting stopping],
      stopping: %i[stopped]
    }.freeze

    attr_reader :current_state, :hostname, :state_changed_at, :startup_started_at

    def initialize(hostname, logger: nil, config: nil)
      @hostname = hostname
      @logger = logger || Logger.new
      @config = config || ConfigLoader.new
      @current_state = :stopped
      @state_changed_at = Time.now
      @startup_started_at = nil
      @state_history = []
    end

    # Transition to a new state
    def transition_to(new_state)
      new_state = new_state.to_sym

      unless STATES.include?(new_state)
        raise StateError, "Invalid state: #{new_state}. Valid states: #{STATES.join(', ')}"
      end

      unless can_transition_to?(new_state)
        raise StateError, "Cannot transition from #{@current_state} to #{new_state}"
      end

      old_state = @current_state
      @current_state = new_state
      @state_changed_at = Time.now

      # Track startup timing
      if new_state == :starting
        @startup_started_at = Time.now
      elsif old_state == :starting && new_state != :starting
        @startup_started_at = nil
      end

      # Record state change in history
      @state_history << {
        from: old_state,
        to: new_state,
        timestamp: @state_changed_at
      }

      # Keep only recent history (last 50 transitions)
      @state_history = @state_history.last(50)

      @logger.info("#{@hostname}: State changed from #{old_state} to #{new_state}")

      new_state
    end

    # Check if the app should be stopped (idle for too long)
    def should_stop?
      return false unless @current_state == :idle

      idle_timeout = @config.get('idle_timeout') || 900
      time_in_state = Time.now - @state_changed_at

      should_stop = time_in_state >= idle_timeout

      if should_stop
        @logger.debug("#{@hostname}: Should stop - idle for #{time_in_state}s (threshold: #{idle_timeout}s)")
      end

      should_stop
    end

    # Check if the app should be started (has recent requests)
    def should_start?(request_detector)
      return false unless @current_state == :stopped

      has_recent_requests = request_detector.recent_requests?(@hostname)

      if has_recent_requests
        @logger.debug("#{@hostname}: Should start - has recent requests")
      end

      has_recent_requests
    end

    # Check if startup has timed out
    def startup_timed_out?
      return false unless @current_state == :starting
      return false unless @startup_started_at

      startup_timeout = @config.get('startup_timeout') || 60
      time_starting = Time.now - @startup_started_at

      timed_out = time_starting >= startup_timeout

      if timed_out
        @logger.warn("#{@hostname}: Startup timed out after #{time_starting}s (threshold: #{startup_timeout}s)")
      end

      timed_out
    end

    # Get time spent in current state
    def time_in_current_state
      Time.now - @state_changed_at
    end

    # Get time spent starting (if currently starting)
    def time_starting
      return 0 unless @current_state == :starting && @startup_started_at

      Time.now - @startup_started_at
    end

    # Check if transition to new state is valid
    def can_transition_to?(new_state)
      new_state = new_state.to_sym
      return false unless STATES.include?(new_state)
      return true if new_state == @current_state # Allow staying in same state

      allowed_transitions = TRANSITIONS[@current_state] || []
      allowed_transitions.include?(new_state)
    end

    # Get valid next states from current state
    def valid_next_states
      TRANSITIONS[@current_state] || []
    end

    # Get state history
    def state_history(limit: 10)
      @state_history.last(limit)
    end

    # Get state summary for logging/debugging
    def state_summary
      {
        hostname: @hostname,
        current_state: @current_state,
        time_in_state: time_in_current_state.round(2),
        state_changed_at: @state_changed_at,
        startup_started_at: @startup_started_at,
        time_starting: time_starting.round(2),
        should_stop: (@current_state == :idle ? should_stop? : false),
        startup_timed_out: startup_timed_out?
      }
    end

    # Reset state to stopped (useful for error recovery)
    def reset!
      @logger.warn("#{@hostname}: Resetting state to stopped")
      @current_state = :stopped
      @state_changed_at = Time.now
      @startup_started_at = nil

      @state_history << {
        from: :unknown,
        to: :stopped,
        timestamp: @state_changed_at,
        reason: 'reset'
      }
    end

    # Check if the app is in a stable state (not transitioning)
    def stable?
      %i[stopped running idle].include?(@current_state)
    end

    # Check if the app is in a transitioning state
    def transitioning?
      %i[starting stopping].include?(@current_state)
    end

    # Check if the app is active (running or idle)
    def active?
      %i[running idle].include?(@current_state)
    end

    # Check if the app is inactive (stopped or stopping)
    def inactive?
      %i[stopped stopping].include?(@current_state)
    end

    # Force transition for emergency situations (bypasses validation)
    def force_transition_to(new_state, reason: 'forced')
      new_state = new_state.to_sym

      unless STATES.include?(new_state)
        raise StateError, "Invalid state: #{new_state}. Valid states: #{STATES.join(', ')}"
      end

      old_state = @current_state
      @current_state = new_state
      @state_changed_at = Time.now

      if new_state == :starting
        @startup_started_at = Time.now
      elsif old_state == :starting && new_state != :starting
        @startup_started_at = nil
      end

      @state_history << {
        from: old_state,
        to: new_state,
        timestamp: @state_changed_at,
        reason: reason,
        forced: true
      }

      @logger.warn("#{@hostname}: Forced state change from #{old_state} to #{new_state} (#{reason})")

      new_state
    end
  end
end
