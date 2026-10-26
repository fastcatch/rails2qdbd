# frozen_string_literal: true

require "test_helper"

class WriterTest < Minitest::Test
  include Rails2qdbd::Catalog

  def writer = Rails2qdbd::Writer.new

  def id_column(type = "bigint") = Column.new(name: "id", type: type, null: false)

  def table(name, *columns, primary_key: ["id"], **attrs)
    Table.new(name: name, columns: columns, primary_key: primary_key, **attrs)
  end

  def render(table, **kwargs) = writer.render_table(table, **kwargs)

  def test_basic_table
    tenants = table("tenants",
                    Column.new(name: "is_demo", type: "boolean", null: false, default: false),
                    Column.new(name: "locked_at", type: "datetime"),
                    id_column,
                    Column.new(name: "name", type: "string", null: false))

    assert_equal <<~TXT.chomp, render(tenants)
      tenants
      -
      id PK bigint
      is_demo boolean default=false
      locked_at datetime NULL
      name string
    TXT
  end

  def test_types
    things = table("things", id_column,
                   Column.new(name: "lat", type: "decimal", precision: 10, scale: 7),
                   Column.new(name: "code", type: "string", limit: 50),
                   Column.new(name: "count", type: "integer", limit: 8),
                   Column.new(name: "roles", type: "string", array: true),
                   Column.new(name: "at", type: "datetime", precision: 6),
                   Column.new(name: "odd", type: "double precision"))
    lines = render(things).lines(chomp: true)

    assert_equal "lat decimal(10,7) NULL", lines[3]
    assert_equal "code string(50) NULL", lines[4]
    assert_equal "count integer NULL", lines[5]
    assert_equal "roles string[] NULL", lines[6]
    assert_equal "at datetime(6) NULL", lines[7]
    assert_equal "odd double_precision NULL", lines[8]
  end

  def test_single_column_indexes
    users = table("users", id_column,
                  Column.new(name: "email", type: "string", null: false),
                  Column.new(name: "org_id", type: "bigint", null: false),
                  indexes: [Index.new(columns: ["email"], unique: true), Index.new(columns: ["org_id"]),
                            Index.new(columns: ["id"], unique: true)])

    assert_equal ["id PK bigint", "email string UNIQUE", "org_id bigint INDEX"], render(users).lines(chomp: true).drop(2)
  end

  def test_composite_partial_expression_index_and_check_notes
    users = table("users", id_column, Column.new(name: "a", type: "string"),
                  indexes: [Index.new(columns: %w[tenant_id email_address], unique: true),
                            Index.new(columns: %w[a b], where: "(status = 'closed')"),
                            Index.new(expression: "lower(name)")],
                  checks: ["price >= 0"])

    assert_equal ["# unique index (tenant_id, email_address)",
                  "# index (a, b) where (status = 'closed')",
                  "# index (lower(name))",
                  "# check (price >= 0)",
                  "users"], render(users).lines(chomp: true).first(5)
  end

  def test_relationship_inline
    posts = table("posts", id_column,
                  Column.new(name: "tenant_id", type: "bigint", null: false),
                  Column.new(name: "author_id", type: "bigint"),
                  indexes: [Index.new(columns: ["tenant_id"])])
    relationships = {
      %w[posts tenant_id] => Relationship.new(from_table: "posts", from_column: "tenant_id", to_table: "tenants", to_column: "id"),
      %w[posts author_id] => Relationship.new(from_table: "posts", from_column: "author_id", to_table: "users",
                                              to_column: "id", cardinality: :one_to_one),
    }
    lines = render(posts, relationships: relationships).lines(chomp: true)

    assert_equal "tenant_id bigint INDEX FK >- tenants.id", lines[3]
    assert_equal "author_id bigint NULL FK - users.id", lines[4]
  end

  def test_defaults_quoting
    assert_equal "false", Rails2qdbd::Writer.format_default(false)
    assert_equal "0.5", Rails2qdbd::Writer.format_default(0.5)
    assert_equal "trial", Rails2qdbd::Writer.format_default("trial")
    assert_equal '"#ffffff"', Rails2qdbd::Writer.format_default("#ffffff")
    assert_equal '"a b"', Rails2qdbd::Writer.format_default("a b")
    assert_equal %("say 'hi'"), Rails2qdbd::Writer.format_default('say "hi"')
    assert_equal '""', Rails2qdbd::Writer.format_default("")
    assert_equal "[]", Rails2qdbd::Writer.format_default([])
    assert_equal "[a,b]", Rails2qdbd::Writer.format_default(%w[a b])
    assert_equal "{}", Rails2qdbd::Writer.format_default({})
    assert_nil Rails2qdbd::Writer.format_default(nil)
  end

  def test_defaults_survive_qdbd_parsing
    colors = table("colors", id_column,
                   Column.new(name: "hex", type: "string", default: "#ffffff"),
                   Column.new(name: "label", type: "string", default: "a b", null: false),
                   Column.new(name: "quote", type: "string", default: 'say "hi"'),
                   Column.new(name: "empty", type: "string", default: ""))
    columns = qdbd_compile(render(colors)).dig("tables", "colors", "columns")

    assert_equal "#ffffff", columns.dig("hex", "default")
    assert columns.dig("hex", "nullable")
    assert_equal "a b", columns.dig("label", "default")
    refute columns.dig("label", "nullable")
    assert_equal "say 'hi'", columns.dig("quote", "default")
    assert_equal "", columns.dig("empty", "default")
  end

  def test_documentation_comments
    people = table("people", id_column,
                   Column.new(name: "mood", type: "mood", enum_values: %w[happy sad], comment: "How they feel\nright now"),
                   Column.new(name: "norm", type: "string", generated: "lower(name) (stored)"),
                   comment: "People # and more")
    text = render(people, table_notes: ["STI: Admin"], column_notes: { "mood" => ["see #42"] })

    assert_equal <<~TXT.chomp, text
      # People ＃ and more
      # STI: Admin
      people
      -
      id PK bigint
      # How they feel
      # right now
      # enum: happy, sad
      # see ＃42
      mood mood NULL
      # generated: lower(name) (stored)
      norm string NULL
    TXT
    compiled = qdbd_compile(text).dig("tables", "people")
    assert_equal ["People ＃ and more", "STI: Admin"], compiled["comments"]
    assert_equal ["How they feel", "right now", "enum: happy, sad", "see ＃42"], compiled.dig("columns", "mood", "comments")
  end

  def test_quoting_identifiers
    assert_equal "users", Rails2qdbd::Writer.quote_identifier("users")
    assert_equal '"order items"', Rails2qdbd::Writer.quote_identifier("order items")
    assert_equal '"public.users"', Rails2qdbd::Writer.quote_identifier("public.users")
  end

  def test_pk_variants
    memberships = table("memberships", Column.new(name: "org_id", type: "bigint", null: false),
                        Column.new(name: "user_id", type: "bigint", null: false), Column.new(name: "role", type: "string"),
                        primary_key: %w[user_id org_id])
    join = table("tags_posts", Column.new(name: "tag_id", type: "bigint"), primary_key: [])

    assert_equal ["org_id PK bigint", "user_id PK bigint", "role string NULL"], render(memberships).lines(chomp: true).drop(2)
    refute_match(/PK/, render(join))
  end

  def test_index_on_part_of_a_composite_pk_is_noted
    memberships = table("memberships", Column.new(name: "org_id", type: "bigint", null: false),
                        Column.new(name: "user_id", type: "bigint", null: false),
                        primary_key: %w[org_id user_id], indexes: [Index.new(columns: ["user_id"])])

    assert_equal <<~TXT.chomp, render(memberships)
      # index (user_id)
      memberships
      -
      org_id PK bigint
      user_id PK bigint
    TXT
  end

  def test_render_file
    text = writer.render_file(tables_text: ["a\n-\nid PK bigint", "b\n-\nid PK bigint"], inputs: ["db/schema.rb", "app/models"])

    assert_equal <<~TXT, text
      # Generated by rails2qdbd #{Rails2qdbd::VERSION} from db/schema.rb, app/models.
      # Re-run the conversion to refresh; manual edits will be overwritten.

      a
      -
      id PK bigint

      b
      -
      id PK bigint
    TXT
  end

  def test_output_passes_qdbd_check
    tenants = table("tenants", id_column, Column.new(name: "name", type: "string", default: "#x y"))
    posts = table('order "items"', id_column, Column.new(name: "tenant_id", type: "bigint"),
                  indexes: [Index.new(columns: %w[tenant_id name], unique: true)], comment: "multi\nline # comment")
    rels = { ['order "items"', "tenant_id"] => Relationship.new(from_table: 'order "items"', from_column: "tenant_id",
                                                                to_table: "tenants", to_column: "id") }
    text = writer.render_file(tables_text: [render(tenants), render(posts, relationships: rels)], inputs: ["db/schema.rb"])

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "schema.txt"), text)
      assert_qdbd_valid(File.join(dir, "schema.txt"))
    end
    assert_equal 1, qdbd_compile(text)["relationships"].size
  end
end
