# frozen_string_literal: true

require_relative "lib/ruboto/version"

Gem::Specification.new do |spec|
  spec.name = "ruboto-ai"
  spec.version = Ruboto::VERSION
  spec.authors = ["Akhil Gautam"]
  spec.email = []

  spec.summary = "Minimal agentic coding assistant for the terminal"
  spec.description = "A fast, autonomous coding assistant built in Ruby, powered by multiple LLM providers via OpenRouter API. Features agentic tools for file manipulation, command execution, and codebase exploration."
  spec.homepage = "https://github.com/akhil-gautam/ruboto-ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    Dir["{bin,lib}/**/*", "LICENSE.txt", "README.md"].reject do |f|
      File.directory?(f) || f.match?(%r{\A(?:\.claude|docs)/})
    end
  end
  spec.bindir = "bin"
  spec.executables = ["ruboto-ai"]
  spec.require_paths = ["lib"]

  # Runtime dependencies - none! Pure Ruby stdlib only
end
