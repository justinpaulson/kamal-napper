# frozen_string_literal: true

require 'time'
require 'set'
require 'json'

module KamalNapper
  # Log parsing and request detection with fallback mechanisms
  class RequestDetector
    class DetectionError < StandardError; end

    LOG_PATH = '/var/log/kamal-proxy'
    TIMESTAMP_FILE_PREFIX = '/tmp/kamal_napper_last_request'

    def initialize(logger: nil, config: nil)
      @logger = logger || Logger.new
      @config = config || ConfigLoader.new
      @last_request_times = {}
    end

    # Get the last request time for a specific hostname
    def last_request_time(hostname)
      # Try to get from kamal-proxy logs first
      log_time = parse_access_logs(hostname)
      return log_time if log_time

      # Fallback to timestamp files
      timestamp_file_time = read_timestamp_file(hostname)
      return timestamp_file_time if timestamp_file_time

      # Return cached time if available
      @last_request_times[hostname]
    end

    # Check if a hostname has received requests recently
    def recent_requests?(hostname, within_seconds: nil)
      within_seconds ||= @config.get('idle_timeout') || 900

      last_time = last_request_time(hostname)
      return false unless last_time

      Time.now - last_time < within_seconds
    end

    # Update the last request time for a hostname (manual tracking)
    def update_last_request_time(hostname, time = Time.now)
      @last_request_times[hostname] = time
      write_timestamp_file(hostname, time)
      @logger.debug("Updated last request time for #{hostname}: #{time}")
    end

    # Parse all available hostnames from logs
    def detected_hostnames
      hostnames = Set.new

      # Get hostnames from log files
      hostnames.merge(parse_hostnames_from_logs)

      # Get hostnames from timestamp files
      hostnames.merge(parse_hostnames_from_timestamp_files)

      # Get hostnames from memory
      hostnames.merge(@last_request_times.keys)

      # Filter out kamal-napper self-hostnames at the source
      filtered_hostnames = hostnames.reject do |hostname|
        is_self_hostname = hostname&.include?('kamal-napper') || 
                          hostname&.include?('naptime') ||
                          hostname == 'kamal-napper.justinpaulson.com'
        if is_self_hostname
          @logger.debug("RequestDetector: Filtering out self-hostname: #{hostname}")
        end
        is_self_hostname
      end

      filtered_hostnames.to_a
    end

    # Get request statistics for a hostname
    def request_stats(hostname, hours_back: 24)
      stats = {
        hostname: hostname,
        last_request: last_request_time(hostname),
        request_count: 0,
        first_request: nil,
        hours_analyzed: hours_back
      }

      begin
        log_entries = parse_log_entries(hostname, hours_back: hours_back)

        if log_entries.any?
          stats[:request_count] = log_entries.size
          stats[:first_request] = log_entries.map { |entry| entry[:timestamp] }.min
          stats[:last_request] = log_entries.map { |entry| entry[:timestamp] }.max
        end
      rescue DetectionError => e
        @logger.warn("Could not analyze request stats for #{hostname}: #{e.message}")
      end

      stats
    end

    private

    def parse_kamal_proxy_logs(hostname)
      latest_time = nil
      
      begin
        # Get logs from kamal-proxy container (last 1000 lines to avoid too much data)
        result = `docker logs kamal-proxy --tail 1000 2>/dev/null`
        return nil if result.empty?
        
        result.lines.each do |line|
          line.strip!
          next if line.empty?
          
          begin
            # Parse JSON log entry
            log_entry = JSON.parse(line)
            next unless log_entry['msg'] == 'Request'
            next unless log_entry['host'] == hostname
            
            # Skip automated/system requests that shouldn't count as user activity
            next if automated_request?(log_entry)
            
            # Parse timestamp
            timestamp = Time.parse(log_entry['time'])
            
            if latest_time.nil? || timestamp > latest_time
              latest_time = timestamp
            end
          rescue JSON::ParserError, ArgumentError
            # Skip non-JSON lines or invalid timestamps
            next
          end
        end
      rescue StandardError => e
        @logger.warn("Error parsing kamal-proxy logs: #{e.message}")
        return nil
      end
      
      latest_time
    end

    def automated_request?(log_entry)
      # Get request details
      path = log_entry['path'] || log_entry['uri'] || '/'
      user_agent = log_entry['user_agent'] || log_entry['user-agent'] || ''
      method = log_entry['method'] || 'GET'
      hostname = log_entry['host'] || ''
      
      # Filter out health check requests
      if path.match?(%r{^/(health|status|ping|ready|alive)/?$})
        @logger.debug("Filtering health check request: #{hostname} #{method} #{path}")
        return true
      end
      
      # Filter out Let's Encrypt ACME challenges
      if path.start_with?('/.well-known/acme-challenge/')
        @logger.debug("Filtering ACME challenge: #{hostname} #{path}")
        return true
      end
      
      # Filter out common bot/crawler user agents
      bot_patterns = [
        /bot/i, /crawler/i, /spider/i, /scraper/i,
        /google/i, /bing/i, /yahoo/i, /baidu/i,
        /uptimerobot/i, /pingdom/i, /monitor/i,
        /check/i, /scan/i, /probe/i
      ]
      
      bot_patterns.each do |pattern|
        if user_agent.match?(pattern)
          @logger.debug("Filtering bot request: #{hostname} #{method} #{path} UA: #{user_agent[0..50]}")
          return true
        end
      end
      
      # Filter out HEAD requests (often automated)
      if method == 'HEAD'
        @logger.debug("Filtering HEAD request: #{hostname} #{path}")
        return true
      end
      
      # Filter out requests with no user agent (often automated)
      if user_agent.empty?
        @logger.debug("Filtering request with no user agent: #{hostname} #{method} #{path}")
        return true
      end
      
      # Log legitimate requests for debugging
      @logger.debug("Allowing request: #{hostname} #{method} #{path} UA: #{user_agent[0..50]}")
      
      false
    end

    def parse_access_logs(hostname)
      # Parse kamal-proxy container logs for JSON entries
      latest_time = parse_kamal_proxy_logs(hostname)
      return latest_time if latest_time

      # Fallback to file-based parsing if available
      return nil unless File.exist?(LOG_PATH)

      begin
        Dir.glob(File.join(LOG_PATH, '*')).each do |log_file|
          next unless File.readable?(log_file)

          File.readlines(log_file).reverse_each do |line|
            entry = parse_log_line(line)
            next unless entry && entry[:hostname] == hostname

            if latest_time.nil? || entry[:timestamp] > latest_time
              latest_time = entry[:timestamp]
            end

            # Stop after finding recent entries to avoid parsing entire log
            break if latest_time && (Time.now - latest_time) > 3600 # 1 hour
          end
        end
      rescue StandardError => e
        @logger.warn("Error parsing access logs: #{e.message}")
        return nil
      end

      latest_time
    end

    def parse_log_line(line)
      # Parse common log format: IP - - [timestamp] "method path protocol" status size "referer" "user-agent" hostname
      # Example: 192.168.1.1 - - [25/Dec/2024:12:00:00 +0000] "GET / HTTP/1.1" 200 1234 "-" "Mozilla/5.0" example.com

      match = line.match(/^(\S+) - - \[([^\]]+)\] "(\S+) (\S+) (\S+)" (\d+) (\S+) "([^"]*)" "([^"]*)"(?:\s+(\S+))?/)
      return nil unless match

      begin
        timestamp_str = match[2]
        # Parse timestamp like "25/Dec/2024:12:00:00 +0000"
        timestamp = Time.strptime(timestamp_str, '%d/%b/%Y:%H:%M:%S %z')

        {
          ip: match[1],
          timestamp: timestamp,
          method: match[3],
          path: match[4],
          protocol: match[5],
          status: match[6].to_i,
          size: match[7],
          referer: match[8],
          user_agent: match[9],
          hostname: match[10] || extract_hostname_from_path(match[4])
        }
      rescue ArgumentError => e
        @logger.debug("Could not parse timestamp in log line: #{e.message}")
        nil
      end
    end

    def extract_hostname_from_path(path)
      # Try to extract hostname from path if it contains host information
      # This is a fallback for logs that don't include hostname at the end
      return nil unless path.include?('/')

      # Look for patterns like /hostname/path or similar
      parts = path.split('/')
      parts.find { |part| part.include?('.') && part.match?(/^[a-zA-Z0-9.-]+$/) }
    end

    def parse_log_entries(hostname, hours_back: 24)
      entries = []
      cutoff_time = Time.now - (hours_back * 3600)

      return entries unless File.exist?(LOG_PATH)

      begin
        Dir.glob(File.join(LOG_PATH, '*')).each do |log_file|
          next unless File.readable?(log_file)

          File.readlines(log_file).each do |line|
            entry = parse_log_line(line)
            next unless entry && entry[:hostname] == hostname
            next if entry[:timestamp] < cutoff_time

            entries << entry
          end
        end
      rescue StandardError => e
        raise DetectionError, "Error parsing log entries: #{e.message}"
      end

      entries.sort_by { |entry| entry[:timestamp] }
    end

    def parse_hostnames_from_logs
      hostnames = Set.new
      
      # First try to get hostnames from kamal-proxy container logs
      begin
        result = `docker logs kamal-proxy --tail 1000 2>/dev/null`
        unless result.empty?
          result.lines.each do |line|
            line.strip!
            next if line.empty?
            
            begin
              log_entry = JSON.parse(line)
              next unless log_entry['msg'] == 'Request'
              
              # Skip automated requests for hostname discovery too
              next if automated_request?(log_entry)
              
              hostname = log_entry['host']
              hostnames << hostname if hostname
            rescue JSON::ParserError
              # Skip non-JSON lines
              next
            end
          end
        end
      rescue StandardError => e
        @logger.warn("Error parsing hostnames from kamal-proxy logs: #{e.message}")
      end
      
      # Fallback to file-based parsing
      return hostnames unless File.exist?(LOG_PATH)

      begin
        Dir.glob(File.join(LOG_PATH, '*')).each do |log_file|
          next unless File.readable?(log_file)

          File.readlines(log_file).each do |line|
            entry = parse_log_line(line)
            hostnames << entry[:hostname] if entry && entry[:hostname]
          end
        end
      rescue StandardError => e
        @logger.warn("Error parsing hostnames from logs: #{e.message}")
      end

      hostnames
    end

    def timestamp_file_path(hostname)
      "#{TIMESTAMP_FILE_PREFIX}_#{hostname.gsub(/[^a-zA-Z0-9.-]/, '_')}"
    end

    def read_timestamp_file(hostname)
      file_path = timestamp_file_path(hostname)
      return nil unless File.exist?(file_path)

      begin
        timestamp_str = File.read(file_path).strip
        Time.parse(timestamp_str)
      rescue StandardError => e
        @logger.debug("Could not read timestamp file for #{hostname}: #{e.message}")
        nil
      end
    end

    def write_timestamp_file(hostname, time)
      file_path = timestamp_file_path(hostname)

      begin
        File.write(file_path, time.iso8601)
      rescue StandardError => e
        @logger.warn("Could not write timestamp file for #{hostname}: #{e.message}")
      end
    end

    def parse_hostnames_from_timestamp_files
      hostnames = Set.new

      begin
        Dir.glob("#{TIMESTAMP_FILE_PREFIX}_*").each do |file_path|
          filename = File.basename(file_path)
          hostname = filename.sub(/^#{File.basename(TIMESTAMP_FILE_PREFIX)}_/, '').gsub('_', '.')
          hostnames << hostname if hostname.include?('.')
        end
      rescue StandardError => e
        @logger.debug("Error parsing hostnames from timestamp files: #{e.message}")
      end

      hostnames
    end
  end
end
