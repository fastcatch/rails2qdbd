# frozen_string_literal: true

require "test_helper"

class CatalogTest < Minitest::Test
  include Rails2qdbd::Catalog

  def test_column_defaults
    column = Column.new(name: "a")

    assert column.null
    refute column.array
    assert_nil column.default
  end

  def test_table_lookups
    index = Index.new(columns: ["name"])
    table = Table.new(name: "users", columns: [Column.new(name: "id"), Column.new(name: "name")], indexes: [index])

    assert_equal "name", table.column("name").name
    assert_nil table.column("missing")
    assert_same index, table.index_on("name")
    assert_nil table.index_on("id")
    assert_equal [], Table.new(name: "t").primary_key
  end

  def test_index_single_column
    assert Index.new(columns: ["a"]).single_column?
    refute Index.new(columns: %w[a b]).single_column?
    refute Index.new(columns: [], expression: "lower(a)").single_column?
    refute Index.new(columns: ["a"], where: "a IS NOT NULL").single_column?
  end

  def test_index_on_ignores_composite_and_partial
    table = Table.new(name: "t", indexes: [Index.new(columns: %w[a b]), Index.new(columns: ["a"], where: "x")])

    assert_nil table.index_on("a")
  end

  def test_diagnostic_to_s
    assert_equal "db/schema.rb:12: warning: odd", Diagnostic.new(severity: :warning, message: "odd", path: "db/schema.rb", line: 12).to_s
    assert_equal "db/schema.rb: error: gone", Diagnostic.new(severity: :error, message: "gone", path: "db/schema.rb").to_s
    assert_equal "warning: bare", Diagnostic.new(severity: :warning, message: "bare").to_s
  end
end
