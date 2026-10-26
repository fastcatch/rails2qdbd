# frozen_string_literal: true

require "test_helper"

class InflectorTest < Minitest::Test
  def test_defaults_match_active_support
    inflector = Rails2qdbd::Inflector.new

    assert_equal "people", inflector.tableize("Person")
    assert_equal "vehicle_care_sessions", inflector.tableize("VehicleCareSession")
    assert_equal "users", inflector.tableize("Admin::User")
    assert_equal "person", inflector.singularize("people")
    assert_equal "boxes", inflector.pluralize("box")
    assert_equal "vehicle_care_session_id", inflector.foreign_key("Fleet::VehicleCareSession")
    assert_equal "ServiceItem", inflector.classify("service_items")
    assert_equal "admin/user", inflector.underscore("Admin::User")
  end

  def test_apply_file_is_local_to_the_instance
    custom = Rails2qdbd::Inflector.new
    diagnostics = custom.apply_file(<<~RUBY, path: "config/initializers/inflections.rb")
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.irregular "goose", "geese"
        inflect.uncountable %w[pokemon]
        inflect.plural(/^(ox)$/i, '\\1en')
        inflect.acronym "API"
      end
    RUBY

    assert_empty diagnostics
    assert_equal "geese", custom.pluralize("goose")
    assert_equal "pokemon", custom.tableize("Pokemon")
    assert_equal "oxen", custom.pluralize("ox")
    assert_equal "api_keys", custom.tableize("APIKey")
    assert_equal "api_key_id", custom.foreign_key("APIKey")
    assert_equal "APIKey", custom.classify("api_keys")

    plain = Rails2qdbd::Inflector.new
    assert_equal "gooses", plain.pluralize("goose")
    assert_equal "pokemons", plain.pluralize("pokemon")
    assert_equal "pokemons", ActiveSupport::Inflector.pluralize("pokemon")
  end

  def test_apply_file_warns_about_other_code
    diagnostics = Rails2qdbd::Inflector.new.apply_file(<<~RUBY, path: "config/initializers/inflections.rb")
      ActiveSupport::Inflector.inflections(:en) do |inflect|
        inflect.human "foo", "Bar"
        inflect.irregular WORDS.first, "x"
      end
    RUBY

    assert_equal ["config/initializers/inflections.rb:2: warning: inflection `human` ignored",
                  "config/initializers/inflections.rb:3: warning: inflection `irregular` with non-literal arguments ignored"],
                 diagnostics.map(&:to_s)
  end
end
