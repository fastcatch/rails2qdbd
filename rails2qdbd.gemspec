# frozen_string_literal: true

require_relative "lib/rails2qdbd/version"

Gem::Specification.new do |spec|
  spec.name = "rails2qdbd"
  spec.version = Rails2qdbd::VERSION
  spec.authors = ["fastcatch"]
  spec.email = ["fastcatch.mail@gmail.com"]
  spec.summary = "Convert a Rails app's schema.rb and models into qdbd (QuickDBD) schema files."
  spec.description = <<~DESC
    rails2qdbd reads db/schema.rb and app/models statically (no app boot, no database)
    and writes QuickDBD-syntax schema files for qdbd, the ER-diagram toolkit.
  DESC
  spec.homepage = "https://github.com/fastcatch/rails2qdbd"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["rails2qdbd"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.1", "< 9"
  spec.add_dependency "prism", ">= 1.0", "< 3"
end
