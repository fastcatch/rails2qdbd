# Synthetic fixture for rails2qdbd's integration tests (not a real application).

ActiveRecord::Schema[8.1].define(version: 2026_10_01_000000) do
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_enum "order_status", ["pending", "paid", "shipped", "cancelled"]

  create_table "accounts", id: :uuid, default: -> { "gen_random_uuid()" }, comment: "Customer accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "key", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "addresses", force: :cascade do |t|
    t.bigint "addressable_id", null: false
    t.string "addressable_type", null: false
    t.string "city", null: false
    t.string "country_code", limit: 2, null: false
    t.index ["addressable_type", "addressable_id"], name: "index_addresses_on_addressable"
  end

  create_table "admin_audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.bigint "user_id"
  end

  create_table "api_keys", force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "token_digest", null: false
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
  end

  create_table "bonuses", force: :cascade do |t|
    t.integer "amount", null: false
    t.bigint "user_id", null: false
  end

  create_table "categories", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "parent_id"
    t.index ["parent_id"], name: "index_categories_on_parent_id"
  end

  create_table "categories_products", id: false, force: :cascade do |t|
    t.bigint "category_id", null: false
    t.bigint "product_id", null: false
    t.index ["category_id", "product_id"], name: "index_categories_products_on_category_id_and_product_id", unique: true
  end

  create_table "countries", primary_key: "code", id: { type: :string, limit: 2 }, force: :cascade do |t|
    t.string "name", null: false
  end

  create_table "legacy_imports", force: :cascade do |t|
    t.text "payload"
  end

  create_table "memberships", primary_key: ["account_id", "user_id"], force: :cascade do |t|
    t.uuid "account_id", null: false
    t.string "role", default: "member", null: false
    t.bigint "user_id", null: false
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", default: 1, null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "number", null: false
    t.datetime "placed_at"
    t.enum "status", default: "pending", null: false, enum_type: "order_status"
    t.decimal "total", precision: 12, scale: 2, default: "0.0", null: false
    t.index "lower((number)::text)", name: "index_orders_on_lower_number"
    t.index ["account_id", "number"], name: "index_orders_on_account_id_and_number", unique: true
    t.index ["placed_at"], name: "index_orders_open", where: "(status = 'pending'::order_status)"
    t.check_constraint "total >= 0", name: "orders_total_not_negative"
  end

  create_table "products", force: :cascade do |t|
    t.string "color", default: "#ffffff", comment: "Display colour # hex"
    t.datetime "created_at", null: false
    t.bigint "legacy_import_id"
    t.string "name", null: false, comment: "Shown in the storefront"
    t.decimal "price", precision: 10, scale: 2, null: false
    t.string "sku", null: false
    t.string "tags", default: [], null: false, array: true
    t.virtual "search_name", type: :string, as: "lower((name)::text)", stored: true
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  create_table "shipments", force: :cascade do |t|
    t.string "carrier", default: "Royal Mail", null: false
    t.bigint "order_id", null: false
    t.datetime "shipped_at"
  end

  create_table "users", force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "role", default: "member", null: false
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "addresses", "countries", column: "country_code", primary_key: "code"
  add_foreign_key "api_keys", "accounts"
  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "memberships", "accounts"
  add_foreign_key "memberships", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "accounts"
  add_foreign_key "products", "legacy_imports"
  add_foreign_key "users", "accounts"
end
