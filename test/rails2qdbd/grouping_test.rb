# frozen_string_literal: true

require "test_helper"

class GroupingTest < Minitest::Test
  def grouping(**overrides)
    Dir.mktmpdir do |root|
      yaml = "default_group: core\ngroups:\n  storage: [\"active_storage_*\"]\n  auth: [users, \"*sessions\"]\n  all_s: [\"s*\"]\n" \
             "exclude: [\"ar_*\", schema_migrations]\n"
      File.write(File.join(root, ".rails2qdbd.yml"), yaml)
      return Rails2qdbd::Grouping.new(Rails2qdbd::Config.load(root, overrides: overrides))
    end
  end

  def test_first_matching_group_wins
    groups = grouping

    assert_equal "storage", groups.group_for("active_storage_blobs")
    assert_equal "auth", groups.group_for("users")
    assert_equal "auth", groups.group_for("sysadmin_sessions")
    assert_equal "all_s", groups.group_for("service_items")
    assert_equal "core", groups.group_for("tenants")
  end

  def test_excluded
    groups = grouping(exclude: ["tmp_{a,b}"])

    assert groups.excluded?("ar_internal_metadata")
    assert groups.excluded?("schema_migrations")
    assert groups.excluded?("tmp_b")
    refute groups.excluded?("users")
  end
end
