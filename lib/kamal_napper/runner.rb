# frozen_string_literal: true

require 'open3'
require 'set'

module KamalNapper
  # Kamal command interface with retry logic and error handling
  class Runner
    class CommandError < StandardError; end

    def initialize(logger: nil, config: nil)
      @logger = logger || Logger.new
      @config = config || ConfigLoader.new
      @max_retries = @config.get('max_retries') || 3
    end

    # Start the Kamal deployment
    def start
      @logger.info("Starting Kamal deployment")
      execute_with_retry('kamal deploy')
    end

    # Stop the Kamal deployment
    def stop
      @logger.info("Stopping Kamal deployment")
      execute_with_retry('kamal app stop')
    end

    # Stop a specific application container by hostname
    def stop_app_container(hostname)
      @logger.info("Stopping container for #{hostname}")
      
      # Find the container name for this hostname
      service_name = hostname.split('.').first
      
      # Try to find and stop the container
      result = execute_command("docker ps --filter 'label=service=#{service_name}' --format '{{.Names}}'", capture_output: true)
      
      if result[:success] && !result[:output].empty?
        container_name = result[:output].strip.lines.first&.strip
        if container_name
          @logger.info("Found container #{container_name} for #{hostname}, stopping it")
          execute_with_retry("docker stop #{container_name}")
          return true
        end
      end
      
      @logger.warn("No container found for #{hostname} (service: #{service_name})")
      false
    end

    # Start a specific application container by hostname  
    def start_app_container(hostname)
      @logger.info("Starting container for #{hostname}")
      
      # Find the stopped container name for this hostname
      service_name = hostname.split('.').first
      
      # Try to find and start the container
      result = execute_command("docker ps -a --filter 'label=service=#{service_name}' --format '{{.Names}}\t{{.Status}}'", capture_output: true)
      
      if result[:success] && !result[:output].empty?
        result[:output].lines.each do |line|
          name, status = line.strip.split("\t", 2)
          if status&.include?('Exited') || status&.include?('Created')
            @logger.info("Found stopped container #{name} for #{hostname}, starting it")
            execute_with_retry("docker start #{name}")
            return true
          end
        end
      end
      
      @logger.warn("No stopped container found for #{hostname} (service: #{service_name})")
      false
    end

    # Enable maintenance mode
    def maintenance(enable: true)
      action = enable ? 'up' : 'down'
      @logger.info("#{enable ? 'Enabling' : 'Disabling'} maintenance mode")
      execute_with_retry("kamal traefik boot --maintenance #{action}")
    end

    # Check if the deployment is live/running
    def live?
      @logger.debug("Checking if deployment is live")
      result = execute_command('kamal app details', capture_output: true)
      result[:success] && result[:output].include?('running')
    rescue CommandError
      false
    end

    # Get deployment status information
    def status
      @logger.debug("Getting deployment status")
      result = execute_with_retry('kamal app details', capture_output: true)
      parse_status_output(result[:output])
    end

    # Execute a custom Kamal command
    def execute_kamal_command(command)
      full_command = command.start_with?('kamal') ? command : "kamal #{command}"
      @logger.info("Executing Kamal command: #{full_command}")
      execute_with_retry(full_command)
    end

    # Discover all Kamal-deployed applications
    def discover_kamal_apps
      @logger.debug("Discovering Kamal-deployed applications")
      apps = {}

      # Method 1: Get apps from Docker containers with Kamal labels
      docker_apps = discover_apps_from_docker
      apps.merge!(docker_apps)

      # Method 2: Get apps from kamal-proxy configuration if available
      proxy_apps = discover_apps_from_proxy
      apps.merge!(proxy_apps)

      @logger.info("Discovered #{apps.size} Kamal applications: #{apps.keys.join(', ')}")
      apps
    end

    # Get list of running Kamal applications from Docker containers
    def discover_apps_from_docker
      @logger.debug("Discovering apps from Docker containers")
      apps = {}

      begin
        # Find containers with Kamal labels
        result = execute_command('docker ps --filter "label=service" --format "{{.Names}}\t{{.Labels}}"', capture_output: true)

        if result[:success]
          result[:output].lines.each do |line|
            name, labels = line.strip.split("\t", 2)
            next unless labels

            # Parse labels to extract service name and other info
            label_hash = parse_docker_labels(labels)

            if label_hash['service'] && label_hash['role'] != 'kamal-proxy'
              service_name = label_hash['service']

              # Try to determine hostname from traefik labels or service name
              hostname = extract_hostname_from_labels(label_hash) || "#{service_name}.justinpaulson.com"

              apps[hostname] = {
                service: service_name,
                container_name: name,
                labels: label_hash
              }
            end
          end
        end
      rescue CommandError => e
        @logger.warn("Failed to discover apps from Docker: #{e.message}")
      end

      apps
    end

    # Get applications from kamal-proxy configuration
    def discover_apps_from_proxy
      @logger.debug("Discovering apps from kamal-proxy")
      apps = {}

      begin
        # Try to get proxy container logs to find configured routes
        result = execute_command('docker logs kamal-proxy-kamal-proxy 2>&1 | grep -E "(rule|Host)" | tail -20', capture_output: true)

        if result[:success]
          hostnames = extract_hostnames_from_proxy_logs(result[:output])

          hostnames.each do |hostname|
            next if hostname.include?('kamal-proxy') # Skip proxy itself

            apps[hostname] = {
              service: hostname.split('.').first,
              hostname: hostname,
              discovered_via: 'proxy_logs'
            }
          end
        end
      rescue CommandError => e
        @logger.debug("Could not read proxy logs: #{e.message}")
      end

      apps
    end

    # Check if a specific app is currently managed by kamal-proxy
    def app_managed_by_proxy?(hostname)
      begin
        result = execute_command("docker exec kamal-proxy-kamal-proxy cat /etc/traefik/traefik.yml 2>/dev/null || echo 'not found'", capture_output: true)
        result[:success] && result[:output].include?(hostname)
      rescue CommandError
        false
      end
    end

    # Get list of all Kamal services from current directory
    def list_kamal_services
      @logger.debug("Listing Kamal services")
      services = []

      begin
        result = execute_command('kamal app list 2>/dev/null || kamal config 2>/dev/null', capture_output: true)

        if result[:success]
          # Parse output to extract service names
          services = parse_kamal_services_output(result[:output])
        end
      rescue CommandError => e
        @logger.debug("Could not list Kamal services: #{e.message}")
      end

      services
    end

    private

    def execute_with_retry(command, capture_output: false, max_retries: nil)
      max_retries ||= @max_retries
      attempt = 0
      last_error = nil

      loop do
        attempt += 1

        begin
          result = execute_command(command, capture_output: capture_output)

          if result[:success]
            @logger.debug("Command succeeded on attempt #{attempt}: #{command}")
            return capture_output ? result : true
          else
            raise CommandError, "Command failed: #{result[:error]}"
          end
        rescue CommandError => e
          last_error = e
          @logger.warn("Command failed on attempt #{attempt}/#{max_retries + 1}: #{e.message}")

          if attempt > max_retries
            @logger.error("Command failed after #{max_retries + 1} attempts: #{command}")
            raise e
          end

          # Exponential backoff: 2^attempt seconds
          sleep_time = 2 ** attempt
          @logger.info("Retrying in #{sleep_time} seconds...")
          sleep(sleep_time)
        end
      end
    end

    def execute_command(command, capture_output: false)
      @logger.debug("Executing command: #{command}")

      if capture_output
        stdout, stderr, status = Open3.capture3(command)

        result = {
          success: status.success?,
          output: stdout.strip,
          error: stderr.strip,
          exit_code: status.exitstatus
        }

        unless result[:success]
          @logger.debug("Command failed with exit code #{result[:exit_code]}: #{result[:error]}")
        end

        result
      else
        success = system(command)

        {
          success: success,
          output: '',
          error: success ? '' : 'Command failed',
          exit_code: success ? 0 : 1
        }
      end
    rescue StandardError => e
      @logger.error("Error executing command '#{command}': #{e.message}")
      raise CommandError, "Failed to execute command: #{e.message}"
    end

    def parse_status_output(output)
      status = {
        running: false,
        containers: [],
        last_deployed: nil
      }

      return status if output.nil? || output.empty?

      # Parse container information
      if output.include?('running')
        status[:running] = true

        # Extract container names/IDs if present
        container_lines = output.lines.select { |line| line.include?('running') }
        status[:containers] = container_lines.map(&:strip)
      end

      # Try to extract deployment timestamp if available
      timestamp_match = output.match(/deployed.*?(\d{4}-\d{2}-\d{2}.*?\d{2}:\d{2}:\d{2})/i)
      status[:last_deployed] = timestamp_match[1] if timestamp_match

      status
    end

    # Parse Docker labels string into a hash
    def parse_docker_labels(labels_string)
      labels = {}
      labels_string.split(',').each do |label|
        key, value = label.split('=', 2)
        labels[key] = value if key && value
      end
      labels
    end

    # Extract hostname from Docker labels (traefik rules, etc.)
    def extract_hostname_from_labels(labels)
      # Look for traefik Host rule
      if labels['traefik.http.routers.web.rule']
        match = labels['traefik.http.routers.web.rule'].match(/Host\(`([^`]+)`\)/)
        return match[1] if match
      end

      # Look for other common hostname labels
      labels['hostname'] || labels['domain'] || nil
    end

    # Extract hostnames from kamal-proxy logs
    def extract_hostnames_from_proxy_logs(logs)
      hostnames = Set.new

      logs.lines.each do |line|
        # Look for Host() rules in traefik logs
        if match = line.match(/Host\(`([^`]+)`\)/)
          hostnames.add(match[1])
        end

        # Look for other hostname patterns
        if match = line.match(/host[:\s]+([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/i)
          hostnames.add(match[1])
        end
      end

      hostnames.to_a
    end

    # Parse Kamal services output
    def parse_kamal_services_output(output)
      services = []

      # Look for service names in various Kamal command outputs
      output.lines.each do |line|
        # Match service names from 'kamal app list' or similar
        if match = line.match(/^([a-zA-Z0-9_-]+):\s/)
          services << match[1]
        elsif match = line.match(/service:\s*([a-zA-Z0-9_-]+)/)
          services << match[1]
        end
      end

      services.uniq
    end
  end
end
