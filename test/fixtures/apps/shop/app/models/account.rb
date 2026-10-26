class Account < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :orders
  has_many :memberships
  has_many :addresses, as: :addressable
  has_one :api_key
end
