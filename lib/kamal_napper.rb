# frozen_string_literal: true

require_relative "kamal_napper/version"
require_relative "kamal_napper/logger"
require_relative "kamal_napper/config_loader"
require_relative "kamal_napper/runner"
require_relative "kamal_napper/request_detector"
require_relative "kamal_napper/app_state"
require_relative "kamal_napper/health_checker"
require_relative "kamal_napper/state_persistence"
require_relative "kamal_napper/supervisor"
require_relative "kamal_napper/cli"

module KamalNapper
  class Error < StandardError; end

  # Main entry point for the Kamal Napper functionality
  def self.root
    File.dirname __dir__
  end
end
