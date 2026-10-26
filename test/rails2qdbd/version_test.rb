# frozen_string_literal: true

require "test_helper"

class VersionTest < Minitest::Test
  def test_version_is_semver
    assert_match(/\A\d+\.\d+\.\d+\z/, Rails2qdbd::VERSION)
  end
end
