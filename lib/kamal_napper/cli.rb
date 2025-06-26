# frozen_string_literal: true

require 'thor'
require 'json'
require 'fileutils'
require 'webrick'
require 'thread'

module KamalNapper
  # Command-line interface using Thor with proper error handling
  class CLI < Thor
    class_option :config,
                 aliases: ['-c'],
                 type: :string,
                 desc: 'Path to configuration file'

    class_option :log_level,
                 aliases: ['-l'],
                 type: :string,
                 default: 'info',
                 desc: 'Log level (debug, info, warn, error)'

    def initialize(*args)
      super
      setup_logger
      setup_config
    end

    desc "start", "Start the Kamal Napper daemon"
    option :daemon, aliases: ['-d'], type: :boolean, default: false, desc: 'Run as daemon'
    option :pidfile, aliases: ['-p'], type: :string, desc: 'Path to PID file'
    def start
      if daemon_running?
        error "Kamal Napper daemon is already running (PID: #{read_pidfile})"
        exit 1
      end

      if options[:daemon]
        start_daemon
      else
        start_foreground
      end
    rescue StandardError => e
      error "Failed to start daemon: #{e.message}"
      exit 1
    end

    desc "stop", "Stop the Kamal Napper daemon"
    def stop
      unless daemon_running?
        error "Kamal Napper daemon is not running"
        exit 1
      end

      pid = read_pidfile
      info "Stopping Kamal Napper daemon (PID: #{pid})"

      begin
        Process.kill('TERM', pid)

        # Wait for graceful shutdown
        30.times do
          break unless process_exists?(pid)
          sleep 1
        end

        if process_exists?(pid)
          warn "Daemon didn't stop gracefully, sending KILL signal"
          Process.kill('KILL', pid)
        end

        cleanup_pidfile
        info "Daemon stopped successfully"
      rescue Errno::ESRCH
        warn "Process not found, cleaning up stale PID file"
        cleanup_pidfile
      rescue StandardError => e
        error "Failed to stop daemon: #{e.message}"
        exit 1
      end
    end

    desc "status", "Show status of all managed apps"
    option :json, aliases: ['-j'], type: :boolean, default: false, desc: 'Output as JSON'
    option :verbose, aliases: ['-v'], type: :boolean, default: false, desc: 'Verbose output'
    def status
      unless daemon_running?
        error "Kamal Napper daemon is not running"
        exit 1
      end

      begin
        supervisor = create_supervisor
        status_info = supervisor.status

        if options[:json]
          puts JSON.pretty_generate(status_info)
        else
          display_status(status_info)
        end
      rescue StandardError => e
        error "Failed to get status: #{e.message}"
        exit 1
      end
    end

    desc "stop-all", "Stop all managed applications"
    def stop_all
      unless daemon_running?
        error "Kamal Napper daemon is not running"
        exit 1
      end

      begin
        supervisor = create_supervisor
        stopped_count = supervisor.stop_all_apps
        info "Stopped #{stopped_count} applications"
      rescue StandardError => e
        error "Failed to stop applications: #{e.message}"
        exit 1
      end
    end

    desc "wake HOSTNAME", "Wake up (start) a specific application"
    def wake(hostname)
      unless daemon_running?
        error "Kamal Napper daemon is not running"
        exit 1
      end

      begin
        supervisor = create_supervisor
        if supervisor.wake_app(hostname)
          info "Waking up #{hostname}"
        else
          warn "#{hostname} is already active or starting"
        end
      rescue StandardError => e
        error "Failed to wake #{hostname}: #{e.message}"
        exit 1
      end
    end

    desc "add HOSTNAME", "Add an application to supervision"
    def add(hostname)
      unless daemon_running?
        error "Kamal Napper daemon is not running"
        exit 1
      end

      begin
        supervisor = create_supervisor
        supervisor.add_app(hostname)
        info "Added #{hostname} to supervision"
      rescue StandardError => e
        error "Failed to add #{hostname}: #{e.message}"
        exit 1
      end
    end

    desc "remove HOSTNAME", "Remove an application from supervision"
    def remove(hostname)
      unless daemon_running?
        error "Kamal Napper daemon is not running"
        exit 1
      end

      begin
        supervisor = create_supervisor
        if supervisor.remove_app(hostname)
          info "Removed #{hostname} from supervision"
        else
          warn "#{hostname} was not under supervision"
        end
      rescue StandardError => e
        error "Failed to remove #{hostname}: #{e.message}"
        exit 1
      end
    end

    desc "health HOSTNAME", "Check health of a specific application"
    option :port, aliases: ['-p'], type: :numeric, desc: 'Port to check'
    option :path, type: :string, desc: 'Health check path'
    option :timeout, aliases: ['-t'], type: :numeric, desc: 'Timeout in seconds'
    def health(hostname)
      begin
        health_checker = HealthChecker.new(logger: @logger, config: @config)

        health_options = {}
        health_options[:port] = options[:port] if options[:port]
        health_options[:path] = options[:path] if options[:path]
        health_options[:timeout] = options[:timeout] if options[:timeout]

        health_info = health_checker.health_info(hostname, **health_options)

        if health_info[:healthy]
          info "#{hostname} is healthy (#{health_info[:status_code]}) - #{health_info[:response_time]}s"
        else
          error "#{hostname} is unhealthy: #{health_info[:error] || 'HTTP ' + health_info[:status_code].to_s}"
          exit 1
        end
      rescue StandardError => e
        error "Health check failed: #{e.message}"
        exit 1
      end
    end

    desc "version", "Show version information"
    def version
      puts "Kamal Napper v#{KamalNapper::VERSION}"
    end

    private

    def setup_logger
      log_level = options[:log_level]&.to_sym || :info
      @logger = Logger.new(level: log_level)
    end

    def setup_config
      config_path = options[:config]
      @config = ConfigLoader.new(config_path)

      begin
        @config.validate!
      rescue ConfigLoader::ConfigError => e
        error "Configuration error: #{e.message}"
        exit 1
      end
    end

    def create_supervisor
      Supervisor.new(logger: @logger, config: @config)
    end

    def start_foreground
      info "Starting Kamal Napper in foreground mode"
      supervisor = create_supervisor
      supervisor.start
    end

    def start_daemon
      info "Starting Kamal Napper as daemon"

      # Fork and detach
      pid = fork do
        Process.daemon(true, false)

        # Redirect stdout/stderr to log files if configured
        setup_daemon_logging

        # Write PID file
        write_pidfile(Process.pid)

        # Start health server in background thread
        start_health_server

        # Start supervisor
        supervisor = create_supervisor
        supervisor.start
      end

      Process.detach(pid)
      info "Daemon started with PID: #{pid}"
    end

    def setup_daemon_logging
      log_dir = @config.get('log_dir') || '/var/log/kamal-napper'

      begin
        FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)

        stdout_log = File.open(File.join(log_dir, 'kamal-napper.log'), 'a')
        stderr_log = File.open(File.join(log_dir, 'kamal-napper-error.log'), 'a')

        $stdout.reopen(stdout_log)
        $stderr.reopen(stderr_log)

        $stdout.sync = true
        $stderr.sync = true
      rescue StandardError => e
        warn "Failed to setup daemon logging: #{e.message}"
      end
    end

    def daemon_running?
      return false unless pidfile_exists?

      pid = read_pidfile
      return false unless pid

      process_exists?(pid)
    end

    def process_exists?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true # Process exists but we don't have permission to signal it
    end

    def pidfile_path
      options[:pidfile] || @config.get('pidfile') || '/var/run/kamal-napper.pid'
    end

    def pidfile_exists?
      File.exist?(pidfile_path)
    end

    def read_pidfile
      return nil unless pidfile_exists?

      File.read(pidfile_path).strip.to_i
    rescue StandardError
      nil
    end

    def write_pidfile(pid)
      File.write(pidfile_path, pid.to_s)
    rescue StandardError => e
      warn "Failed to write PID file: #{e.message}"
    end

    def cleanup_pidfile
      File.unlink(pidfile_path) if pidfile_exists?
    rescue StandardError => e
      warn "Failed to cleanup PID file: #{e.message}"
    end

    def display_status(status_info)
      puts "Kamal Napper Status"
      puts "==================="
      puts "Running: #{status_info[:running] ? 'Yes' : 'No'}"
      puts "Apps managed: #{status_info[:app_count]}"
      puts "Poll interval: #{status_info[:poll_interval]}s"
      puts

      if status_info[:apps].empty?
        puts "No applications currently managed"
      else
        puts "Applications:"
        puts "-------------"

        status_info[:apps].each do |hostname, app_info|
          state_color = state_color_code(app_info[:current_state])
          time_in_state = format_duration(app_info[:time_in_state])

          puts "#{hostname}:"
          puts "  State: #{state_color}#{app_info[:current_state]}#{reset_color} (#{time_in_state})"
          puts "  Changed: #{app_info[:state_changed_at]}"

          if options[:verbose]
            puts "  Should stop: #{app_info[:should_stop]}"
            puts "  Startup timed out: #{app_info[:startup_timed_out]}"
            puts "  Time starting: #{app_info[:time_starting]}s" if app_info[:time_starting] > 0
          end

          puts
        end
      end
    end

    def state_color_code(state)
      case state
      when :running
        "\e[32m" # Green
      when :idle
        "\e[33m" # Yellow
      when :stopped
        "\e[31m" # Red
      when :starting, :stopping
        "\e[36m" # Cyan
      else
        ""
      end
    end

    def reset_color
      "\e[0m"
    end

    def format_duration(seconds)
      if seconds < 60
        "#{seconds.round}s"
      elsif seconds < 3600
        "#{(seconds / 60).round}m"
      else
        "#{(seconds / 3600).round(1)}h"
      end
    end

    def info(message)
      @logger.info(message)
    end

    def warn(message)
      @logger.warn(message)
    end

    def error(message)
      @logger.error(message)
    end

    def start_health_server
      Thread.new do
        begin
          # Try port 80 first, fallback to 3000 if permission denied
          port = 80
          begin
            server = WEBrick::HTTPServer.new(
              Port: port,
              Logger: WEBrick::Log.new('/dev/null'),
              AccessLog: [],
              BindAddress: '0.0.0.0'
            )
          rescue Errno::EACCES, Errno::EADDRINUSE => e
            warn "Cannot bind to port #{port}: #{e.message}, trying port 3000"
            port = 3000
            server = WEBrick::HTTPServer.new(
              Port: port,
              Logger: WEBrick::Log.new('/dev/null'),
              AccessLog: [],
              BindAddress: '0.0.0.0'
            )
          end

          info "Health server starting on port #{port}"

          server.mount_proc '/health' do |req, res|
            res.status = 200
            res['Content-Type'] = 'application/json'
            res.body = JSON.generate({
              status: 'ok',
              service: 'kamal-napper',
              version: KamalNapper::VERSION,
              timestamp: Time.now.iso8601,
              port: port
            })
          end

          server.mount_proc '/' do |req, res|
            res.status = 200
            res['Content-Type'] = 'text/plain'
            res.body = "Kamal Napper is running on port #{port}"
          end

          # Set up signal handlers for graceful shutdown
          trap('INT') { server.shutdown }
          trap('TERM') { server.shutdown }

          info "Health server started successfully on port #{port}"
          server.start
        rescue StandardError => e
          error "Health server failed to start: #{e.message}"
          error "Backtrace: #{e.backtrace.join("\n")}"
        end
      end
    end
  end
end
