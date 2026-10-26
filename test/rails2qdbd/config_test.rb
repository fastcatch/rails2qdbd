# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def with_app(config_yaml = nil)
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".rails2qdbd.yml"), config_yaml) if config_yaml
      yield root
    end
  end

  def test_defaults_without_a_file
    with_app do |root|
      config = Rails2qdbd::Config.load(root)

      assert_nil config.output
      assert_equal ["db/schema.rb"], config.schemas
      assert_equal "app/models", config.models
      assert_equal "config/initializers/inflections.rb", config.inflections
      assert_equal [], config.exclude
      assert_equal "app", config.default_group
      assert_equal({}, config.groups)
      assert_nil config.path
      assert_equal root, config.app_root
    end
  end

  def test_values_from_the_file
    with_app(<<~YAML) do |root|
      output: schema/
      schemas: [db/schema.rb, db/queue_schema.rb]
      models: false
      inflections: false
      exclude: [ar_internal_metadata]
      default_group: core
      groups:
        storage: "active_storage_*"
        auth: [users, "sessions*"]
    YAML
      config = Rails2qdbd::Config.load(root)

      assert_equal "schema/", config.output
      assert_equal %w[db/schema.rb db/queue_schema.rb], config.schemas
      assert_equal [false, false], [config.models, config.inflections]
      assert_equal "core", config.default_group
      assert_equal({ "storage" => ["active_storage_*"], "auth" => ["users", "sessions*"] }, config.groups)
      assert_equal ".rails2qdbd.yml", config.path
    end
  end

  def test_overrides_win_and_excludes_add_up
    with_app("output: schema/\nexclude: [a]\n") do |root|
      config = Rails2qdbd::Config.load(root, overrides: { output: "out.txt", exclude: ["b"], models: false })

      assert_equal "out.txt", config.output
      assert_equal %w[a b], config.exclude
      refute config.models
    end
  end

  def test_explicit_path
    with_app do |root|
      File.write(File.join(root, "custom.yml"), "default_group: x\n")

      assert_equal "x", Rails2qdbd::Config.load(root, path: "custom.yml").default_group
      error = assert_raises(Rails2qdbd::Error) { Rails2qdbd::Config.load(root, path: "missing.yml") }
      assert_equal "config file not found: missing.yml", error.message
    end
  end

  def test_invalid_files
    with_app("colour: red\n") do |root|
      error = assert_raises(Rails2qdbd::Error) { Rails2qdbd::Config.load(root) }
      assert_equal "unknown config key in .rails2qdbd.yml: colour", error.message
    end
    with_app("groups: [a]\n") do |root|
      error = assert_raises(Rails2qdbd::Error) { Rails2qdbd::Config.load(root) }
      assert_equal "groups in .rails2qdbd.yml must map group names to table globs", error.message
    end
    with_app("- just\n- a list\n") do |root|
      assert_raises(Rails2qdbd::Error) { Rails2qdbd::Config.load(root) }
    end
  end
end
