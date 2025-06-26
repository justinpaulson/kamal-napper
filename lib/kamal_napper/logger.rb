# frozen_string_literal: true

module KamalNapper
  # Simple logging utility with timestamp formatting and proper output formatting
  class Logger
    LEVELS = {
      debug: 0,
      info: 1,
      warn: 2,
      error: 3
    }.freeze

    def initialize(level: :info, output: $stdout)
      @level = LEVELS[level] || LEVELS[:info]
      @output = output
    end

    # Log an info message
    def info(message)
      log(:info, message)
    end

    # Log a warning message
    def warn(message)
      log(:warn, message)
    end

    # Log an error message
    def error(message)
      log(:error, message)
    end

    # Log a debug message
    def debug(message)
      log(:debug, message)
    end

    private

    def log(level, message)
      return unless should_log?(level)

      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      formatted_level = level.to_s.upcase.ljust(5)

      @output.puts "[#{timestamp}] #{formatted_level} #{message}"
      @output.flush
    end

    def should_log?(level)
      LEVELS[level] >= @level
    end
  end
end
