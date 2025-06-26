# frozen_string_literal: true

require 'yaml'
require 'erb'

module KamalNapper
  # YAML configuration loader with environment variable overrides and validation
  class ConfigLoader
    class ConfigError < Error; end

    DEFAULT_CONFIG = {
      'idle_timeout' => 900,
      'poll_interval' => 10,
      'startup_timeout' => 60,
      'max_retries' => 3,
      'log_level' => 'info'
    }.freeze

    REQUIRED_SETTINGS = %w[idle_timeout poll_interval startup_timeout max_retries].freeze

    def initialize(config_path = nil)
      @config_path = config_path || default_config_path
      @config = load_config
    end

    # Get a configuration value
    def get(key)
      @config[key.to_s]
    end

    # Get configuration value with environment variable override
    def get_with_env(key, env_var = nil)
      env_var ||= "KAMAL_NAPPER_#{key.to_s.upcase}"
      ENV[env_var] || get(key)
    end

    # Get all configuration as a hash
    def to_h
      @config.dup
    end

    # Reload configuration from file
    def reload!
      @config = load_config
    end

    # Validate that all required settings are present
    def validate!
      missing_settings = REQUIRED_SETTINGS.select { |setting| @config[setting].nil? }

      unless missing_settings.empty?
        raise ConfigError, "Missing required configuration settings: #{missing_settings.join(', ')}"
      end

      validate_types!
    end

    private

    def default_config_path
      File.join(KamalNapper.root, 'config', 'kamal_napper.yml')
    end

    def load_config
      config = DEFAULT_CONFIG.dup

      if File.exist?(@config_path)
        begin
          file_content = File.read(@config_path)
          erb_content = ERB.new(file_content).result
          yaml_config = YAML.safe_load(erb_content) || {}
          config.merge!(yaml_config)
        rescue Psych::SyntaxError => e
          raise ConfigError, "Invalid YAML in config file #{@config_path}: #{e.message}"
        rescue StandardError => e
          raise ConfigError, "Error loading config file #{@config_path}: #{e.message}"
        end
      end

      # Apply environment variable overrides
      apply_env_overrides(config)

      config
    end

    def apply_env_overrides(config)
      config.each_key do |key|
        env_var = "KAMAL_NAPPER_#{key.upcase}"
        if ENV[env_var]
          config[key] = convert_env_value(ENV[env_var], config[key])
        end
      end
    end

    def convert_env_value(env_value, default_value)
      case default_value
      when Integer
        env_value.to_i
      when Float
        env_value.to_f
      when TrueClass, FalseClass
        env_value.downcase == 'true'
      else
        env_value
      end
    end

    def validate_types!
      errors = []

      errors << "idle_timeout must be a positive integer" unless @config['idle_timeout'].is_a?(Integer) && @config['idle_timeout'] > 0
      errors << "poll_interval must be a positive integer" unless @config['poll_interval'].is_a?(Integer) && @config['poll_interval'] > 0
      errors << "startup_timeout must be a positive integer" unless @config['startup_timeout'].is_a?(Integer) && @config['startup_timeout'] > 0
      errors << "max_retries must be a non-negative integer" unless @config['max_retries'].is_a?(Integer) && @config['max_retries'] >= 0

      unless errors.empty?
        raise ConfigError, "Configuration validation errors: #{errors.join(', ')}"
      end
    end
  end
end
