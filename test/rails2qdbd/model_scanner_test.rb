# frozen_string_literal: true

require "test_helper"

class ModelScannerTest < Minitest::Test
  APPLICATION_RECORD = <<~RUBY
    class ApplicationRecord < ActiveRecord::Base
      primary_abstract_class
    end
  RUBY

  def scan(files)
    @scanner = Rails2qdbd::ModelScanner.new
    @scanner.scan(sources: { "app/models/application_record.rb" => APPLICATION_RECORD }.merge(files))
  end

  def diagnostics = @scanner.diagnostics

  def test_class_and_namespace
    models = scan("app/models/admin/user.rb" => <<~RUBY, "app/models/admin/account.rb" => <<~RUBY2)
      module Admin
        class User < ApplicationRecord
        end
      end
    RUBY
      class Admin::Account < ApplicationRecord
      end
    RUBY2

    assert_equal %w[Admin::Account Admin::User ApplicationRecord], models.keys.sort
    assert_equal "ApplicationRecord", models["Admin::User"].superclass
    assert_equal ["app/models/admin/user.rb", 2], [models["Admin::User"].path, models["Admin::User"].line]
  end

  def test_abstract_detection
    models = scan("app/models/legacy_record.rb" => <<~RUBY, "app/models/widget.rb" => "class Widget < LegacyRecord\nend\n")
      class LegacyRecord < ApplicationRecord
        self.abstract_class = true
      end
    RUBY

    assert models["ApplicationRecord"].abstract
    assert models["LegacyRecord"].abstract
    refute models["Widget"].abstract
    assert_equal "LegacyRecord", models["Widget"].superclass
  end

  def test_table_name_and_primary_key_overrides
    models = scan("app/models/person.rb" => <<~RUBY)
      class Person < ApplicationRecord
        self.table_name = "humans"
        self.primary_key = "uid"
      end
    RUBY

    assert_equal %w[humans uid], [models["Person"].table_name, models["Person"].primary_key]
  end

  def test_composite_primary_key_override
    models = scan("app/models/membership.rb" => "class Membership < ApplicationRecord\n  self.primary_key = [:account_id, :user_id]\nend\n")

    assert_equal %w[account_id user_id], models["Membership"].primary_key
  end

  def test_associations
    models = scan("app/models/post.rb" => <<~RUBY)
      class Post < ApplicationRecord
        belongs_to :author, class_name: "User", foreign_key: :written_by_id, optional: true
        belongs_to :subject, polymorphic: true
        has_many :comments, -> { order(:id) }, dependent: :destroy
        has_many :likes, as: :likeable
        has_many :readers, through: :readings
        has_one :cover, class_name: "Image", foreign_key: "post_ref", primary_key: "ref"
        has_and_belongs_to_many :tags, join_table: "post_tags"
      end
    RUBY
    associations = models["Post"].associations.map { |a| [a.macro, a.name, a.options] }

    assert_equal [
      [:belongs_to, "author", { class_name: "User", foreign_key: "written_by_id" }],
      [:belongs_to, "subject", { polymorphic: true }],
      [:has_many, "comments", {}],
      [:has_many, "likes", { as: "likeable" }],
      [:has_many, "readers", { through: "readings" }],
      [:has_one, "cover", { class_name: "Image", foreign_key: "post_ref", primary_key: "ref" }],
      [:has_and_belongs_to_many, "tags", { join_table: "post_tags" }],
    ], associations
    assert_equal 2, models["Post"].associations.first.line
    assert_empty diagnostics
  end

  def test_with_options_block
    models = scan("app/models/team.rb" => <<~RUBY)
      class Team < ApplicationRecord
        with_options class_name: "Person" do |team|
          team.belongs_to :lead
          belongs_to :coach
        end
      end
    RUBY

    assert_equal [["lead", { class_name: "Person" }], ["coach", { class_name: "Person" }]],
                 models["Team"].associations.map { |a| [a.name, a.options] }
  end

  def test_non_literal_option_warns
    models = scan("app/models/post.rb" => <<~RUBY)
      class Post < ApplicationRecord
        belongs_to :owner, class_name: owner_class_name
        belongs_to :user
      end
    RUBY

    assert_equal ["user"], models["Post"].associations.map(&:name)
    assert_equal ["app/models/post.rb:2: warning: Post belongs_to :owner: non-literal class_name, skipped"], diagnostics.map(&:to_s)
  end

  def test_enums
    models = scan("app/models/order.rb" => <<~RUBY)
      class Order < ApplicationRecord
        enum :status, { pending: "pending", paid: "paid" }, default: "pending"
        enum kind: [:retail, :wholesale], _prefix: true
        enum :channel, %w[web shop]
        enum priority: { low: 0, high: 10 }
      end
    RUBY

    assert_equal({ "status" => %w[pending paid], "kind" => %w[retail wholesale], "channel" => %w[web shop],
                   "priority" => ["low (0)", "high (10)"] }, models["Order"].enums)
  end

  def test_enum_values_as_keywords
    models = scan("app/models/invoice.rb" => <<~RUBY)
      class Invoice < ApplicationRecord
        enum :state, draft: 0, sent: 1, prefix: true
      end
    RUBY

    assert_equal({ "state" => ["draft (0)", "sent (1)"] }, models["Invoice"].enums)
    assert_empty diagnostics
  end

  def test_attachments
    models = scan("app/models/photo.rb" => <<~RUBY)
      class Photo < ApplicationRecord
        has_one_attached :image
        has_many_attached :thumbnails
      end
    RUBY

    assert_equal [["image", :one], ["thumbnails", :many]], models["Photo"].attachments
  end

  def test_concern_included_block
    models = scan("app/models/concerns/tenant_scoped.rb" => <<~RUBY, "app/models/invoice.rb" => <<~RUBY2)
      module TenantScoped
        extend ActiveSupport::Concern

        included do
          belongs_to :tenant
          has_one_attached :logo
        end
      end
    RUBY
      class Invoice < ApplicationRecord
        include TenantScoped
        belongs_to :customer
      end
    RUBY2
    invoice = models["Invoice"]

    assert_equal %w[tenant customer], invoice.associations.map(&:name)
    assert_equal "app/models/concerns/tenant_scoped.rb", invoice.associations.first.path
    assert_equal ["TenantScoped"], invoice.includes
    assert_equal [["logo", :one]], invoice.attachments
    refute models.key?("TenantScoped")
  end

  def test_nested_concern_applies_once_per_class
    models = scan(
      "app/models/concerns/taggable.rb" => <<~RUBY,
        module Taggable
          extend ActiveSupport::Concern
          included do
            has_many :tags
            belongs_to :owner, class_name: owner_class_name
          end
        end
      RUBY
      "app/models/concerns/annotated.rb" => <<~RUBY,
        module Annotated
          extend ActiveSupport::Concern
          included do
            include Taggable
            has_many :notes
          end
        end
      RUBY
      "app/models/photo.rb" => "class Photo < ApplicationRecord\n  include Annotated\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\n  include Annotated\nend\n",
      "app/models/video.rb" => "class Video < ApplicationRecord\n  include Annotated\nend\n",
    )

    assert_equal [%w[tags notes]] * 3, %w[Photo Post Video].map { |name| models[name].associations.map(&:name) }
    assert_equal ["app/models/concerns/taggable.rb:5: warning: Taggable belongs_to :owner: non-literal class_name, skipped"],
                 diagnostics.map(&:to_s)
  end

  def test_concern_that_only_includes_another_concern
    models = scan("app/models/concerns/taggable.rb" => <<~RUBY, "app/models/concerns/publishable.rb" => <<~RUBY2,
      module Taggable
        extend ActiveSupport::Concern
        included do
          has_many :tags
        end
      end
    RUBY
      module Publishable
        extend ActiveSupport::Concern
        include Taggable
      end
    RUBY2
                  "app/models/post.rb" => "class Post < ApplicationRecord\n  include Publishable\nend\n")

    assert_equal %w[tags], models["Post"].associations.map(&:name)
    refute models.key?("Publishable")
  end

  def test_reopened_class_merges
    models = scan("app/models/a.rb" => "class Item < ApplicationRecord\n  belongs_to :x\nend\n",
                  "app/models/b.rb" => "class Item\n  belongs_to :y\nend\n")

    assert_equal %w[x y], models["Item"].associations.map(&:name)
  end

  def test_non_models_ignored
    models = scan(
      "app/models/current.rb" => "class Current < ActiveSupport::CurrentAttributes\n  attribute :user\nend\n",
      "app/models/concerns/categories.rb" => "module Categories\n  KEYS = %w[a b].freeze\n  def self.label(k) = k\nend\n",
      "app/models/price_calculator.rb" => "class PriceCalculator\n  belongs_to :nonsense, class_name: x\n  def call = 1\nend\n",
      "app/models/order.rb" => "class Order < ApplicationRecord\n  class InvalidTransition < StandardError; end\nend\n",
    )

    assert_equal %w[ApplicationRecord Order], models.keys.sort
    assert_empty diagnostics
  end

  def test_syntax_error_warns
    scan("app/models/broken.rb" => "class Broken < ApplicationRecord\n")

    assert_equal :warning, diagnostics.first.severity
    assert_equal "app/models/broken.rb", diagnostics.first.path
  end
end
