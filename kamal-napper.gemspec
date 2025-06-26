# frozen_string_literal: true

require_relative "lib/kamal_napper/version"

Gem::Specification.new do |spec|
  spec.name = "kamal-napper"
  spec.version = KamalNapper::VERSION
  spec.authors = ["Justin Paulson"]
  spec.email = ["justin@example.com"]

  spec.summary = "A tool for managing idle Kamal deployments"
  spec.description = "Kamal Napper automatically manages idle Kamal deployments by scaling them down when not in use and scaling them back up when needed."
  spec.homepage = "https://github.com/justinpaulson/kamal-napper"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/justinpaulson/kamal-napper"
  spec.metadata["changelog_uri"] = "https://github.com/justinpaulson/kamal-napper/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "bin"
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "thor", "~> 1.0"
  spec.add_dependency "yaml", "~> 0.2"

  # Development dependencies
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
