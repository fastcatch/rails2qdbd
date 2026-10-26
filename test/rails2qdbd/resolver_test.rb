# frozen_string_literal: true

require "test_helper"

class ResolverTest < Minitest::Test
  SCHEMA = <<~RUBY
    ActiveRecord::Schema[8.1].define(version: 1) do
      create_table "tenants" do |t|
        t.string "name"
      end
      create_table "users" do |t|
        t.bigint "tenant_id"
        t.string "type"
        t.index ["tenant_id"]
      end
      create_table "price_list_imports" do |t|
        t.bigint "imported_by_id", null: false
        t.bigint "tenant_id"
      end
      create_table "sessions" do |t|
        t.bigint "user_id"
      end
      create_table "payments" do |t|
        t.bigint "visit_id"
        t.index ["visit_id"], unique: true
      end
      create_table "visits" do |t|
        t.string "status"
      end
      create_table "audit_entries" do |t|
        t.bigint "auditable_id"
        t.string "auditable_type"
        t.string "kind"
      end
      create_table "posts" do |t|
        t.bigint "author_id"
      end
      create_table "tags" do |t|
      end
      create_table "posts_tags", id: false do |t|
        t.bigint "post_id"
        t.bigint "tag_id"
      end
      create_table "active_storage_attachments" do |t|
        t.bigint "record_id", null: false
        t.string "record_type", null: false
      end
      create_table "article_labels", id: false do |t|
        t.bigint "post_id"
        t.bigint "tag_id"
      end
      %FKS%
    end
  RUBY

  # Model files come as a hash or as brace-less "path" => source pairs (which Ruby passes as keywords).
  def resolve(models_source = {}, foreign_keys: "", **files)
    models_source = models_source.merge(files.transform_keys(&:to_s))
    schema = Rails2qdbd::SchemaParser.new.parse(SCHEMA.sub("%FKS%", foreign_keys), path: "db/schema.rb")
    sources = { "app/models/application_record.rb" => "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n" }
    models_source.each { |path, source| sources["app/models/#{path}"] = source }
    models = Rails2qdbd::ModelScanner.new.scan(sources: sources)
    @resolver = Rails2qdbd::Resolver.new(schema, models, inflector: Rails2qdbd::Inflector.new)
    @resolver.resolve
  end

  def edges(resolution)
    resolution.relationships.values.map { |r| [r.from_table, r.from_column, r.to_table, r.to_column, r.cardinality, r.source] }
  end

  def warnings(resolution) = resolution.diagnostics.map(&:to_s)

  def test_database_fks_become_relationships
    resolution = resolve({}, foreign_keys: 'add_foreign_key "users", "tenants"')

    assert_equal [["users", "tenant_id", "tenants", "id", :many_to_one, :database]], edges(resolution)
    assert_empty resolution.column_notes
  end

  def test_excluded_tables_drop_relationships
    schema = Rails2qdbd::SchemaParser.new.parse(SCHEMA.sub("%FKS%", 'add_foreign_key "users", "tenants"
      add_foreign_key "sessions", "users"'), path: "db/schema.rb")
    resolution = Rails2qdbd::Resolver.new(schema, {}, inflector: Rails2qdbd::Inflector.new,
                                                      excluded: ->(table) { table == "tenants" }).resolve

    assert_equal [%w[sessions user_id users id]], edges(resolution).map { |edge| edge.first(4) }
    assert_equal({ "users" => { "tenant_id" => ["references tenants (excluded)"] } }, resolution.column_notes)
  end

  def test_database_fk_to_unknown_table_warns
    resolution = resolve({}, foreign_keys: 'add_foreign_key "users", "accounts", column: "tenant_id"')

    assert_empty resolution.relationships
    assert_equal ["warning: foreign key users.tenant_id -> accounts.id: table accounts not found, skipped"], warnings(resolution)
  end

  def test_belongs_to_without_db_fk
    resolution = resolve("price_list_import.rb" => <<~RUBY, "user.rb" => "class User < ApplicationRecord\nend\n")
      class PriceListImport < ApplicationRecord
        belongs_to :imported_by, class_name: "User"
        belongs_to :tenant
      end
    RUBY

    assert_equal [["price_list_imports", "imported_by_id", "users", "id", :many_to_one, :model],
                  ["price_list_imports", "tenant_id", "tenants", "id", :many_to_one, :model]], edges(resolution)
    assert_equal ["relationship from model association (no database constraint)"],
                 resolution.column_notes.dig("price_list_imports", "imported_by_id")
    assert_empty warnings(resolution)
  end

  def test_has_many_and_has_one_infer_child_fk
    resolution = resolve("user.rb" => <<~RUBY, "visit.rb" => <<~RUBY2)
      class User < ApplicationRecord
        has_many :sessions
        has_many :writings, class_name: "Post", foreign_key: :author_id
      end
    RUBY
      class Visit < ApplicationRecord
        has_one :payment
      end
    RUBY2

    assert_equal [["sessions", "user_id", "users", "id", :many_to_one, :model],
                  ["posts", "author_id", "users", "id", :many_to_one, :model],
                  ["payments", "visit_id", "visits", "id", :one_to_one, :model]], edges(resolution)
  end

  def test_has_one_without_unique_index_is_one_to_one
    resolution = resolve("user.rb" => "class User < ApplicationRecord\n  has_one :session\nend\n")

    assert_equal :one_to_one, resolution.relationships[%w[sessions user_id]].cardinality
  end

  def test_composite_model_primary_key_falls_back_to_schema
    resolution = resolve("user.rb" => "class User < ApplicationRecord\n  self.primary_key = [:id, :tenant_id]\n  has_many :sessions\nend\n")

    assert_equal %w[sessions user_id users id], edges(resolution).first.first(4)
  end

  def test_unique_index_makes_one_to_one
    resolution = resolve({}, foreign_keys: 'add_foreign_key "payments", "visits"')

    assert_equal :one_to_one, resolution.relationships[%w[payments visit_id]].cardinality
  end

  def test_habtm_join_table
    resolution = resolve("post.rb" => <<~RUBY, "tag.rb" => "class Tag < ApplicationRecord\nend\n")
      class Post < ApplicationRecord
        has_and_belongs_to_many :tags
        has_and_belongs_to_many :labels, class_name: "Tag", join_table: "article_labels"
      end
    RUBY

    assert_equal [%w[posts_tags post_id posts id], %w[posts_tags tag_id tags id],
                  %w[article_labels post_id posts id], %w[article_labels tag_id tags id]],
                 edges(resolution).map { |edge| edge.first(4) }
  end

  def test_polymorphic_notes
    resolution = resolve("audit_entry.rb" => <<~RUBY, "tenant.rb" => <<~RUBY2, "user.rb" => <<~RUBY3)
      class AuditEntry < ApplicationRecord
        belongs_to :auditable, polymorphic: true, optional: true
      end
    RUBY
      class Tenant < ApplicationRecord
        has_many :audit_entries, as: :auditable
      end
    RUBY2
      class User < ApplicationRecord
        has_many :audit_entries, as: :auditable
      end
    RUBY3

    assert_empty resolution.relationships
    assert_equal ["polymorphic (type in auditable_type): Tenant, User"], resolution.column_notes.dig("audit_entries", "auditable_id")
  end

  def test_polymorphic_custom_columns
    resolution = resolve("audit_entry.rb" => <<~RUBY, "tenant.rb" => <<~RUBY2, "user.rb" => <<~RUBY3)
      class AuditEntry < ApplicationRecord
        belongs_to :subject, polymorphic: true, foreign_key: :auditable_id, foreign_type: :kind
      end
    RUBY
      class Tenant < ApplicationRecord
        has_many :audit_entries, as: :subject, foreign_key: :auditable_id, foreign_type: :kind
      end
    RUBY2
      class User < ApplicationRecord
        has_many :audit_entries, as: :ghost
      end
    RUBY3

    assert_equal ["polymorphic (type in kind): Tenant"], resolution.column_notes.dig("audit_entries", "auditable_id")
    assert_equal ["app/models/user.rb:2: warning: User has_many :audit_entries: column audit_entries.ghost_id not found, skipped"],
                 warnings(resolution)
  end

  def test_abstract_parents_pass_declarations_to_subclasses
    resolution = resolve(
      "application_record.rb" => <<~RUBY,
        class ApplicationRecord < ActiveRecord::Base
          primary_abstract_class
          belongs_to :tenant
        end
      RUBY
      "status_record.rb" => <<~RUBY,
        class StatusRecord < ApplicationRecord
          self.abstract_class = true
          enum :status, %w[open closed]
          has_one_attached :receipt
        end
      RUBY
      "user.rb" => "class User < ApplicationRecord\nend\n",
      "admin.rb" => "class Admin < User\nend\n",
      "price_list_import.rb" => "class PriceListImport < ApplicationRecord\nend\n",
      "session.rb" => "class Session < ApplicationRecord\nend\n",
      "visit.rb" => "class Visit < StatusRecord\nend\n",
    )

    assert_equal [%w[price_list_imports tenant_id tenants id], %w[users tenant_id tenants id]],
                 edges(resolution).map { |edge| edge.first(4) }.sort
    assert_equal ["enum: open, closed"], resolution.column_notes.dig("visits", "status")
    assert_equal ["attachments: receipt (one)"], resolution.table_notes["visits"]
    assert_equal ["app/models/application_record.rb:3: warning: Session belongs_to :tenant: column sessions.tenant_id not found, skipped",
                  "app/models/application_record.rb:3: warning: Visit belongs_to :tenant: column visits.tenant_id not found, skipped"],
                 warnings(resolution)
  end

  def test_sti_shares_base_table
    resolution = resolve("user.rb" => "class User < ApplicationRecord\nend\n", "admin.rb" => <<~RUBY, "guest.rb" => "class Guest < User\nend\n")
      class Admin < User
        belongs_to :tenant
      end
    RUBY

    assert_equal "users", @resolver.table_for(Rails2qdbd::Catalog::Model.new(name: "Admin", superclass: "User"))
    assert_equal [%w[users tenant_id tenants id]], edges(resolution).map { |edge| edge.first(4) }
    assert_equal ["STI: Admin, Guest"], resolution.table_notes["users"]
  end

  def test_model_enum_and_attachment_notes
    resolution = resolve("visit.rb" => <<~RUBY)
      class Visit < ApplicationRecord
        enum :status, { open: "open", closed: "closed" }
        enum :missing, %w[a b]
        has_one_attached :image
        has_many_attached :files
      end
    RUBY

    assert_equal ["enum: open, closed"], resolution.column_notes.dig("visits", "status")
    assert_nil resolution.column_notes.dig("visits", "missing")
    assert_equal ["attachments: image (one), files (many)"], resolution.table_notes["visits"]
  end

  def test_active_storage_record_targets_come_from_attachments
    resolution = resolve("visit.rb" => "class Visit < ApplicationRecord\n  has_one_attached :image\nend\n",
                         "user.rb" => "class User < ApplicationRecord\n  has_many_attached :files\nend\n")

    assert_equal ["polymorphic (type in record_type): User, Visit"],
                 resolution.column_notes.dig("active_storage_attachments", "record_id")
  end

  def test_stale_association_warns
    resolution = resolve("post.rb" => <<~RUBY, "ghost.rb" => "class Ghost < ApplicationRecord\n  belongs_to :tenant\nend\n")
      class Post < ApplicationRecord
        belongs_to :editor, class_name: "Nobody"
        belongs_to :tenant
        has_many :comments
      end
    RUBY

    assert_empty resolution.relationships
    assert_equal [
      "app/models/ghost.rb:2: warning: Ghost belongs_to :tenant: table ghosts not found, skipped",
      "app/models/post.rb:2: warning: Post belongs_to :editor: class Nobody not found, skipped",
      "app/models/post.rb:3: warning: Post belongs_to :tenant: column posts.tenant_id not found, skipped",
      "app/models/post.rb:4: warning: Post has_many :comments: class Comment not found, skipped",
    ], warnings(resolution)
  end

  def test_db_fk_wins_conflict
    resolution = resolve({ "post.rb" => "class Post < ApplicationRecord\n  belongs_to :author, class_name: \"Tenant\"\nend\n" },
                         foreign_keys: 'add_foreign_key "posts", "users", column: "author_id"')

    assert_equal [%w[posts author_id users id]], edges(resolution).map { |edge| edge.first(4) }
    assert_equal ["app/models/post.rb:2: warning: Post belongs_to :author: points to tenants.id but the database foreign key " \
                  "points to users.id; using the database"], warnings(resolution)
  end

  def test_namespaced_class_lookup
    resolution = resolve("admin/session.rb" => <<~RUBY, "admin/user.rb" => <<~RUBY2, "tenant.rb" => "class Tenant < ApplicationRecord\nend\n")
      module Admin
        class Session < ApplicationRecord
          self.table_name = "sessions"
          belongs_to :user
        end
      end
    RUBY
      module Admin
        class User < ApplicationRecord
          self.table_name = "users"
          belongs_to :tenant
        end
      end
    RUBY2

    assert_equal [%w[sessions user_id users id], %w[users tenant_id tenants id]], edges(resolution).map { |edge| edge.first(4) }
  end
end
