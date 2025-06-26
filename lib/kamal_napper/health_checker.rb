# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'timeout'

module KamalNapper
  # HTTP health checking with timeout handling and custom endpoints
  class HealthChecker
    class HealthCheckError < StandardError; end

    DEFAULT_TIMEOUT = 10
    DEFAULT_PATH = '/health'
    DEFAULT_PORT = 80

    def initialize(logger: nil, config: nil)
      @logger = logger || Logger.new
      @config = config || ConfigLoader.new
      @timeout = @config.get('health_check_timeout') || DEFAULT_TIMEOUT
    end

    # Check if an app is responding to HTTP requests
    def healthy?(hostname, port: nil, path: nil, timeout: nil)
      port ||= @config.get('health_check_port') || DEFAULT_PORT
      path ||= @config.get('health_check_path') || DEFAULT_PATH
      timeout ||= @timeout

      @logger.debug("Health checking #{hostname}:#{port}#{path} (timeout: #{timeout}s)")

      begin
        Timeout.timeout(timeout) do
          uri = URI("http://#{hostname}:#{port}#{path}")

          Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
            request = Net::HTTP::Get.new(uri)
            response = http.request(request)

            success = response.code.to_i < 400

            if success
              @logger.debug("#{hostname}: Health check passed (#{response.code})")
            else
              @logger.debug("#{hostname}: Health check failed (#{response.code})")
            end

            success
          end
        end
      rescue Timeout::Error
        @logger.debug("#{hostname}: Health check timed out after #{timeout}s")
        false
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
        @logger.debug("#{hostname}: Health check connection failed: #{e.class}")
        false
      rescue SocketError => e
        @logger.debug("#{hostname}: Health check DNS resolution failed: #{e.message}")
        false
      rescue StandardError => e
        @logger.warn("#{hostname}: Health check error: #{e.message}")
        false
      end
    end

    # Check multiple hostnames at once
    def check_multiple(hostnames, **options)
      results = {}

      hostnames.each do |hostname|
        results[hostname] = healthy?(hostname, **options)
      end

      results
    end

    # Wait for an app to become healthy (with retries)
    def wait_for_health(hostname, max_attempts: 30, delay: 2, **options)
      @logger.info("#{hostname}: Waiting for health check to pass...")

      max_attempts.times do |attempt|
        if healthy?(hostname, **options)
          @logger.info("#{hostname}: Health check passed after #{attempt + 1} attempts")
          return true
        end

        if attempt < max_attempts - 1
          @logger.debug("#{hostname}: Health check failed, retrying in #{delay}s (attempt #{attempt + 1}/#{max_attempts})")
          sleep(delay)
        end
      end

      @logger.warn("#{hostname}: Health check failed after #{max_attempts} attempts")
      false
    end

    # Get detailed health check information
    def health_info(hostname, port: nil, path: nil, timeout: nil)
      port ||= @config.get('health_check_port') || DEFAULT_PORT
      path ||= @config.get('health_check_path') || DEFAULT_PATH
      timeout ||= @timeout

      info = {
        hostname: hostname,
        port: port,
        path: path,
        timeout: timeout,
        healthy: false,
        response_time: nil,
        status_code: nil,
        error: nil,
        checked_at: Time.now
      }

      start_time = Time.now

      begin
        Timeout.timeout(timeout) do
          uri = URI("http://#{hostname}:#{port}#{path}")

          Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
            request = Net::HTTP::Get.new(uri)
            response = http.request(request)

            info[:response_time] = (Time.now - start_time).round(3)
            info[:status_code] = response.code.to_i
            info[:healthy] = response.code.to_i < 400
          end
        end
      rescue Timeout::Error
        info[:response_time] = (Time.now - start_time).round(3)
        info[:error] = "Timeout after #{timeout}s"
      rescue Errno::ECONNREFUSED
        info[:response_time] = (Time.now - start_time).round(3)
        info[:error] = "Connection refused"
      rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH
        info[:response_time] = (Time.now - start_time).round(3)
        info[:error] = "Host unreachable"
      rescue SocketError => e
        info[:response_time] = (Time.now - start_time).round(3)
        info[:error] = "DNS resolution failed: #{e.message}"
      rescue StandardError => e
        info[:response_time] = (Time.now - start_time).round(3)
        info[:error] = e.message
      end

      info
    end

    # Check if health checking is properly configured
    def configured?
      # Health checking is always available with defaults
      true
    end

    # Get health check configuration summary
    def config_summary
      {
        timeout: @timeout,
        default_port: @config.get('health_check_port') || DEFAULT_PORT,
        default_path: @config.get('health_check_path') || DEFAULT_PATH
      }
    end
  end
end
