# frozen_string_literal: true

require "test_helper"

# What RubyGems.org shows and enforces; `gem build` warns about anything missing here.
class GemspecTest < Minitest::Test
  REPO = "https://github.com/fastcatch/rails2qdbd"

  def spec = @spec ||= Dir.chdir(QdbdHelpers::ROOT) { Gem::Specification.load("rails2qdbd.gemspec") }

  def test_identity_and_links
    assert_equal [["fastcatch"], ["fastcatch@gmail.com"]], [spec.authors, Array(spec.email)]
    assert_equal REPO, spec.homepage
    assert_equal({ "source_code_uri" => REPO,
                   "changelog_uri" => "#{REPO}/blob/main/CHANGELOG.md", "bug_tracker_uri" => "#{REPO}/issues",
                   "rubygems_mfa_required" => "true" }, spec.metadata)
  end

  def test_dependencies_are_bounded
    spec.runtime_dependencies.each do |dependency|
      assert dependency.requirement.requirements.any? { |op, _| ["<", "~>"].include?(op) },
             "#{dependency.name} has no upper bound: #{dependency.requirement}"
    end
  end

  def test_packaged_files
    assert_includes spec.files, "exe/rails2qdbd"
    assert_includes spec.files, "lib/rails2qdbd.rb"
    assert_equal ["rails2qdbd"], spec.executables
    assert_empty spec.files.grep(%r{\A(test|bin|\.github)/})
  end
end
