# frozen_string_literal: true

require "test_helper"

# End-to-end: the synthetic shop app through the real executable, against golden files
# (regenerate with `rake golden` and review the diff), then through qdbd itself.
class ShopIntegrationTest < Minitest::Test
  APP = File.join(QdbdHelpers::ROOT, "test/fixtures/apps/shop")
  EXPECTED = File.join(APP, "expected")
  EXE = File.join(QdbdHelpers::ROOT, "exe/rails2qdbd")
  LIB = File.join(QdbdHelpers::ROOT, "lib")

  def convert_into(dir)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, EXE, APP, "-o", dir)
    assert status.success?, err
    [out, err]
  end

  def test_matches_golden_files
    Dir.mktmpdir do |dir|
      out, err = convert_into(dir)

      assert_equal Dir.children(EXPECTED).sort, Dir.children(dir).sort
      Dir.children(EXPECTED).each do |name|
        assert_equal File.read(File.join(EXPECTED, name)), File.read(File.join(dir, name)), "#{name} differs from golden"
      end
      # Our diagnostics use app-relative paths; Ruby/Bundler's own warnings start with "/".
      diagnostics = err.lines(chomp: true).reject { |line| line.start_with?("/") }
      assert_equal ["app/models/admin/audit_log.rb:7: warning: Admin::AuditLog belongs_to :subject: non-literal class_name, skipped"],
                   diagnostics
      assert_match(/wrote 4 file\(s\) .*: 16 tables, 15 relationships/, out)
    end
  end

  def test_golden_files_are_up_to_date
    _, status = Open3.capture2e(RbConfig.ruby, "-I", LIB, EXE, APP, "-o", EXPECTED, "--check", "-q")

    assert status.success?, "golden files are stale: run `rake golden` and review the diff"
  end

  def test_qdbd_accepts_and_understands_the_output
    assert_qdbd_valid(EXPECTED)
    schema = qdbd_compile_dir(EXPECTED)
    edges = schema["relationships"].map { |r| "#{r.dig('a', 'table')}.#{r.dig('a', 'column')} #{r.dig('a', 'card')}-#{r.dig('b', 'card')} #{r.dig('b', 'table')}.#{r.dig('b', 'column')}" }

    assert_empty schema["diagnostics"]
    assert_equal 16, schema["tables"].size
    assert_includes edges, "bonuses.user_id many-one users.id"            # model-only, needs the custom inflection
    assert_includes edges, "shipments.order_id one-one orders.id"         # has_one, no unique index
    assert_includes edges, "categories.parent_id many-one categories.id"  # self-reference
    assert_includes edges, "addresses.country_code many-one countries.code"
    assert_includes edges, "categories_products.product_id many-one products.id"
    refute(edges.any? { |edge| edge.include?("legacy_imports") })
    assert_equal "#ffffff", schema.dig("tables", "products", "columns", "color", "default")
    assert_equal %w[account_id user_id], schema.dig("tables", "memberships", "columns").values.select { |c| c["pk"] }.map { |c| c["name"] }
  end
end
