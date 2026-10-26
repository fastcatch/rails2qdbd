class User < ApplicationRecord
  include AccountOwned

  ROLES = %w[member owner].freeze

  enum :role, { member: "member", owner: "owner" }

  has_many :bonuses
  has_many :addresses, as: :addressable
  has_many :audit_logs, class_name: "Admin::AuditLog"
  has_many :memberships
end
