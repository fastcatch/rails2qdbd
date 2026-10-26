# frozen_string_literal: true

require "test_helper"

class SchemaParserTest < Minitest::Test
  def parse(body, header: "ActiveRecord::Schema[8.1].define(version: 2026_01_01_000000) do")
    @parser = Rails2qdbd::SchemaParser.new
    @parser.parse("#{header}\n#{body}\nend\n", path: "db/schema.rb")
  end

  def diagnostics = @parser.diagnostics

  def test_implicit_bigint_id
    schema = parse(<<~RUBY)
      create_table "users", force: :cascade do |t|
        t.string "name"
      end
    RUBY
    users = schema.tables.fetch("users")

    assert_equal "8.1", schema.version
    assert_equal %w[id name], users.columns.map(&:name)
    assert_equal "bigint", users.column("id").type
    refute users.column("id").null
    assert_equal ["id"], users.primary_key
    assert_equal 2, users.line
    assert_equal "db/schema.rb", users.path
  end

  def test_legacy_define_header
    schema = parse(<<~RUBY, header: "ActiveRecord::Schema.define(version: 2016_01_01_000000) do")
      create_table "users", id: :serial do |t|
      end
    RUBY

    assert_nil schema.version
    assert_equal "serial", schema.tables["users"].column("id").type
  end

  def test_id_variants
    schema = parse(<<~RUBY)
      create_table "tags_posts", id: false do |t|
        t.bigint "tag_id"
      end
      create_table "docs", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      end
      create_table "countries", primary_key: "code", id: :string do |t|
      end
      create_table "memberships", primary_key: ["org_id", "user_id"] do |t|
        t.bigint "org_id", null: false
        t.bigint "user_id", null: false
      end
    RUBY

    assert_equal [], schema.tables["tags_posts"].primary_key
    assert_equal ["tag_id"], schema.tables["tags_posts"].columns.map(&:name)
    docs_id = schema.tables["docs"].column("id")
    assert_equal ["uuid", "gen_random_uuid()"], [docs_id.type, docs_id.default]
    assert_equal ["code"], schema.tables["countries"].primary_key
    assert_equal "string", schema.tables["countries"].column("code").type
    assert_equal %w[org_id user_id], schema.tables["memberships"].primary_key
    assert_equal %w[org_id user_id], schema.tables["memberships"].columns.map(&:name)
  end

  def test_id_hash_option
    schema = parse(<<~RUBY)
      create_table "countries", primary_key: "code", id: { type: :string, limit: 2 } do |t|
      end
    RUBY
    code = schema.tables["countries"].column("code")

    assert_equal ["string", 2, false], [code.type, code.limit, code.null]
  end

  def test_column_options
    schema = parse(<<~RUBY)
      create_table "things", comment: "Stuff we keep" do |t|
        t.boolean "flag", default: false, null: false
        t.string "plan", default: "trial"
        t.integer "count", default: 0
        t.string "roles", default: [], array: true
        t.datetime "seen_at", default: -> { "CURRENT_TIMESTAMP" }
        t.string "code", limit: 50, comment: "External code"
        t.decimal "lat", precision: 10, scale: 7
        t.column "legacy", :text
      end
    RUBY
    table = schema.tables["things"]

    assert_equal "Stuff we keep", table.comment
    assert_equal [false, false], [table.column("flag").default, table.column("flag").null]
    assert_equal "trial", table.column("plan").default
    assert_equal 0, table.column("count").default
    assert_equal [[], true], [table.column("roles").default, table.column("roles").array]
    assert_equal "CURRENT_TIMESTAMP", table.column("seen_at").default
    assert_equal [50, "External code"], [table.column("code").limit, table.column("code").comment]
    assert_equal [10, 7], [table.column("lat").precision, table.column("lat").scale]
    assert_equal "text", table.column("legacy").type
    assert table.column("plan").null
  end

  def test_virtual_column
    schema = parse(<<~RUBY)
      create_table "cars" do |t|
        t.string "plate"
        t.virtual "plate_norm", type: :string, as: "lower(plate)", stored: true
        t.virtual "plate_len", type: :integer, as: "length(plate)"
      end
    RUBY
    cars = schema.tables["cars"]

    assert_equal ["string", "lower(plate) (stored)"], [cars.column("plate_norm").type, cars.column("plate_norm").generated]
    assert_equal "length(plate)", cars.column("plate_len").generated
  end

  def test_indexes
    schema = parse(<<~RUBY)
      create_table "users" do |t|
        t.string "email"
        t.bigint "org_id"
        t.index ["email"], name: "index_users_on_email", unique: true
        t.index ["org_id", "email"], name: "idx_org_email"
        t.index "lower((email)::text)", name: "idx_lower_email"
        t.index ["org_id"], name: "idx_partial", where: "(email IS NOT NULL)"
      end
      add_index "users", ["org_id"], name: "index_users_on_org_id"
    RUBY
    indexes = schema.tables["users"].indexes

    assert_equal 5, indexes.size
    assert_equal [["email"], true], [indexes[0].columns, indexes[0].unique]
    assert_equal %w[org_id email], indexes[1].columns
    assert_equal ["lower((email)::text)", []], [indexes[2].expression, indexes[2].columns]
    assert_equal "(email IS NOT NULL)", indexes[3].where
    assert_equal [["org_id"], false, "index_users_on_org_id"], [indexes[4].columns, indexes[4].unique, indexes[4].name]
  end

  def test_foreign_keys
    schema = parse(<<~RUBY)
      add_foreign_key "comments", "posts"
      add_foreign_key "comments", "users", column: "author_id"
      add_foreign_key "orders", "countries", column: "country_code", primary_key: "code"
      add_foreign_key "people", "companies"
    RUBY
    fks = schema.foreign_keys.map { |fk| [fk.from_table, fk.from_column, fk.to_table, fk.to_column] }

    assert_equal [
      %w[comments post_id posts id],
      %w[comments author_id users id],
      %w[orders country_code countries code],
      %w[people company_id companies id],
    ], fks
  end

  def test_references_and_timestamps
    schema = parse(<<~RUBY)
      create_table "comments" do |t|
        t.references :commentable, polymorphic: true, null: false
        t.belongs_to :user, foreign_key: true
        t.references :editor, foreign_key: { to_table: :users }, index: false
        t.timestamps
      end
    RUBY
    comments = schema.tables["comments"]

    assert_equal %w[id commentable_type commentable_id user_id editor_id created_at updated_at], comments.columns.map(&:name)
    assert_equal ["string", false], [comments.column("commentable_type").type, comments.column("commentable_type").null]
    assert_equal "bigint", comments.column("user_id").type
    assert_equal [%w[commentable_type commentable_id], ["user_id"]], comments.indexes.map(&:columns)
    assert_equal [%w[comments user_id users id], %w[comments editor_id users id]],
                 schema.foreign_keys.map { |fk| [fk.from_table, fk.from_column, fk.to_table, fk.to_column] }
    assert_equal ["datetime", false], [comments.column("created_at").type, comments.column("created_at").null]
  end

  def test_pg_enums
    schema = parse(<<~RUBY)
      create_enum "mood", ["happy", "sad"]
      create_table "people" do |t|
        t.enum "current_mood", enum_type: "mood", null: false
      end
    RUBY
    column = schema.tables["people"].column("current_mood")

    assert_equal({ "mood" => %w[happy sad] }, schema.enums)
    assert_equal ["mood", %w[happy sad]], [column.type, column.enum_values]
  end

  def test_check_constraints_are_kept
    schema = parse(<<~RUBY)
      create_table "items" do |t|
        t.integer "price"
        t.check_constraint "price >= 0", name: "price_positive"
      end
    RUBY

    assert_equal ["price >= 0"], schema.tables["items"].checks
  end

  def test_unknown_calls
    parse(<<~RUBY)
      enable_extension "pg_catalog.plpgsql"
      execute "SELECT 1"
      create_table "a" do |t|
        t.mystery
      end
    RUBY

    assert_equal 1, diagnostics.size
    assert_equal ["db/schema.rb", 5, :warning], [diagnostics[0].path, diagnostics[0].line, diagnostics[0].severity]
    assert_match(/mystery/, diagnostics[0].message)
  end

  def test_syntax_error_is_reported
    @parser = Rails2qdbd::SchemaParser.new
    schema = @parser.parse("create_table \"a\" do |t|\n", path: "db/schema.rb")

    assert_empty schema.tables
    assert_equal :error, diagnostics.first.severity
  end

  def test_parse_files_merges_and_flags_duplicates
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "db"))
      File.write(File.join(root, "db/schema.rb"), "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"a\" do |t|\n  end\nend\n")
      File.write(File.join(root, "db/queue_schema.rb"), "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"b\" do |t|\n  end\n  create_table \"a\" do |t|\n  end\nend\n")
      @parser = Rails2qdbd::SchemaParser.new
      schema = @parser.parse_files(%w[db/schema.rb db/queue_schema.rb], root: root)

      assert_equal %w[a b], schema.tables.keys.sort
      assert_equal "db/schema.rb", schema.tables["a"].path
      assert_equal ["db/queue_schema.rb:4: error: table \"a\" already defined at db/schema.rb:2"], diagnostics.map(&:to_s)
    end
  end

  def test_parse_files_missing_file
    error = assert_raises(Rails2qdbd::Error) { Rails2qdbd::SchemaParser.new.parse_files(["db/schema.rb"], root: Dir.tmpdir) }

    assert_equal "schema file not found: db/schema.rb", error.message
  end
end
