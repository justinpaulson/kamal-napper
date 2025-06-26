# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tempfile'

module KamalNapper
  # State persistence to disk with atomic writes and error handling
  class StatePersistence
    class PersistenceError < StandardError; end

    DEFAULT_STATE_DIR = '/var/lib/kamal-napper'
    DEFAULT_STATE_FILE = 'state.yml'

    def initialize(logger: nil, config: nil, state_dir: nil)
      @logger = logger || Logger.new
      @config = config || ConfigLoader.new
      @state_dir = state_dir || @config.get('state_dir') || DEFAULT_STATE_DIR
      @state_file = File.join(@state_dir, DEFAULT_STATE_FILE)

      ensure_state_directory
    end

    # Save app states to disk
    def save_states(app_states)
      @logger.debug("Saving states for #{app_states.size} apps to #{@state_file}")

      state_data = {
        saved_at: Time.now.iso8601,
        version: KamalNapper::VERSION,
        states: serialize_app_states(app_states)
      }

      write_state_file(state_data)
      @logger.info("Successfully saved states for #{app_states.size} apps")
    rescue StandardError => e
      @logger.error("Failed to save states: #{e.message}")
      raise PersistenceError, "Failed to save states: #{e.message}"
    end

    # Load states from disk on daemon startup
    def load_states
      unless File.exist?(@state_file)
        @logger.info("No existing state file found at #{@state_file}")
        return {}
      end

      @logger.debug("Loading states from #{@state_file}")

      begin
        state_data = YAML.safe_load(File.read(@state_file), permitted_classes: [Time, Symbol])

        unless state_data.is_a?(Hash)
          @logger.warn("Invalid state file format, starting with empty states")
          return {}
        end

        states = deserialize_app_states(state_data['states'] || {})
        saved_at = state_data['saved_at']

        @logger.info("Loaded states for #{states.size} apps (saved at #{saved_at})")
        states
      rescue Psych::SyntaxError => e
        @logger.error("Invalid YAML in state file: #{e.message}")
        backup_corrupted_state_file
        {}
      rescue StandardError => e
        @logger.error("Failed to load states: #{e.message}")
        backup_corrupted_state_file
        {}
      end
    end

    # Save a single app state
    def save_app_state(hostname, app_state)
      states = load_states
      states[hostname] = app_state
      save_states(states)
    end

    # Load a single app state
    def load_app_state(hostname)
      states = load_states
      states[hostname]
    end

    # Remove an app state from persistence
    def remove_app_state(hostname)
      states = load_states
      if states.delete(hostname)
        save_states(states)
        @logger.info("Removed state for #{hostname}")
        true
      else
        false
      end
    end

    # Check if state file exists and is readable
    def state_file_exists?
      File.exist?(@state_file) && File.readable?(@state_file)
    end

    # Get state file information
    def state_file_info
      return nil unless File.exist?(@state_file)

      stat = File.stat(@state_file)
      {
        path: @state_file,
        size: stat.size,
        modified_at: stat.mtime,
        readable: File.readable?(@state_file),
        writable: File.writable?(@state_file)
      }
    end

    # Clean up old backup files
    def cleanup_backups(keep_count: 5)
      backup_pattern = "#{@state_file}.backup.*"
      backup_files = Dir.glob(backup_pattern).sort_by { |f| File.mtime(f) }.reverse

      files_to_remove = backup_files[keep_count..-1] || []

      files_to_remove.each do |file|
        begin
          File.delete(file)
          @logger.debug("Removed old backup file: #{file}")
        rescue StandardError => e
          @logger.warn("Failed to remove backup file #{file}: #{e.message}")
        end
      end

      @logger.info("Cleaned up #{files_to_remove.size} old backup files") if files_to_remove.any?
    end

    private

    def ensure_state_directory
      return if Dir.exist?(@state_dir)

      begin
        FileUtils.mkdir_p(@state_dir, mode: 0755)
        @logger.info("Created state directory: #{@state_dir}")
      rescue StandardError => e
        raise PersistenceError, "Failed to create state directory #{@state_dir}: #{e.message}"
      end
    end

    def write_state_file(state_data)
      # Use atomic write to prevent corruption
      temp_file = Tempfile.new(['kamal_napper_state', '.yml'], @state_dir)

      begin
        temp_file.write(YAML.dump(state_data))
        temp_file.flush
        temp_file.fsync # Ensure data is written to disk

        # Atomic move
        File.rename(temp_file.path, @state_file)

        # Set appropriate permissions
        File.chmod(0644, @state_file)

        @logger.debug("Atomically wrote state file: #{@state_file}")
      rescue StandardError => e
        # Clean up temp file on error
        temp_file.close
        File.unlink(temp_file.path) if File.exist?(temp_file.path)
        raise e
      ensure
        temp_file.close unless temp_file.closed?
      end
    end

    def serialize_app_states(app_states)
      serialized = {}

      app_states.each do |hostname, app_state|
        serialized[hostname] = {
          current_state: app_state.current_state,
          state_changed_at: app_state.state_changed_at.iso8601,
          startup_started_at: app_state.startup_started_at&.iso8601,
          state_history: app_state.state_history(limit: 10).map do |entry|
            {
              from: entry[:from],
              to: entry[:to],
              timestamp: entry[:timestamp].iso8601,
              reason: entry[:reason],
              forced: entry[:forced]
            }.compact
          end
        }
      end

      serialized
    end

    def deserialize_app_states(serialized_states)
      app_states = {}

      serialized_states.each do |hostname, state_data|
        begin
          # Create new AppState instance
          app_state = AppState.new(hostname, logger: @logger, config: @config)

          # Restore state without validation (force transition)
          target_state = state_data['current_state']&.to_sym || :stopped
          app_state.force_transition_to(target_state, reason: 'restored_from_disk')

          # Restore timestamps if available
          if state_data['state_changed_at']
            app_state.instance_variable_set(:@state_changed_at, Time.parse(state_data['state_changed_at']))
          end

          if state_data['startup_started_at']
            app_state.instance_variable_set(:@startup_started_at, Time.parse(state_data['startup_started_at']))
          end

          app_states[hostname] = app_state
          @logger.debug("Restored state for #{hostname}: #{target_state}")
        rescue StandardError => e
          @logger.warn("Failed to restore state for #{hostname}: #{e.message}")
          # Create fresh state for this app
          app_states[hostname] = AppState.new(hostname, logger: @logger, config: @config)
        end
      end

      app_states
    end

    def backup_corrupted_state_file
      return unless File.exist?(@state_file)

      backup_path = "#{@state_file}.backup.#{Time.now.to_i}"

      begin
        FileUtils.cp(@state_file, backup_path)
        @logger.info("Backed up corrupted state file to #{backup_path}")
      rescue StandardError => e
        @logger.warn("Failed to backup corrupted state file: #{e.message}")
      end
    end
  end
end
