# -*- encoding: utf-8 -*-
# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "active_record/refined/version"

Gem::Specification.new do |gem|
  gem.name          = "activerecord-refined"
  gem.version       = ActiveRecord::Refined::VERSION
  gem.authors       = ["Shugo Maeda"]
  gem.email         = ["shugo@ruby-lang.org"]
  gem.description   = "Adding clean and powerful query syntax on Active Record using refinements"
  gem.summary       = "Write Active Record queries as Ruby expressions"
  gem.homepage      = "https://github.com/shugo/activerecord-refined"
  gem.license       = "MIT"
  gem.metadata      = {
    "documentation_uri" => "https://rubydoc.info/gems/activerecord-refined",
  }

  gem.files         = `git ls-files -- lib docs examples README.md LICENSE.txt .yardopts activerecord-refined.gemspec`.split($/)
  gem.require_paths = ["lib"]

  # Proc#refined is available since Ruby 4.1. 4.1.0.dev is required to allow
  # ruby-master builds, which sort before the 4.1.0 release.
  gem.required_ruby_version = ">= 4.1.0.dev"

  gem.add_dependency "activerecord", [">= 7.2"]
  gem.add_development_dependency "sqlite3", [">= 0"]
  gem.add_development_dependency "minitest", [">= 0"]
  gem.add_development_dependency "rake", [">= 0"]
  gem.add_development_dependency "simplecov", [">= 0"]
  # What cuts a release: `bump patch --tag`, then push with --follow-tags.
  gem.add_development_dependency "bump", [">= 0"]
  # What benchmark/query_building.rb measures with.
  gem.add_development_dependency "benchmark-ips", [">= 0"]
  gem.add_development_dependency "memory_profiler", [">= 0"]
  # The style is Rails' own: .rubocop.yml is theirs with this repository's
  # paths, and these are the plugins it loads.
  gem.add_development_dependency "rubocop", [">= 0"]
  gem.add_development_dependency "rubocop-minitest", [">= 0"]
  gem.add_development_dependency "rubocop-packaging", [">= 0"]
  gem.add_development_dependency "rubocop-performance", [">= 0"]
  gem.add_development_dependency "rubocop-rails", [">= 0"]
  gem.add_development_dependency "rubocop-md", [">= 0"]
  # What renders the reference: `yard server --reload` serves it locally,
  # and rubydoc.info renders the same .yardopts.
  gem.add_development_dependency "yard", [">= 0"]
end
