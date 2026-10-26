class Order < ApplicationRecord
  include AccountOwned

  with_options dependent: :destroy do
    has_many :order_items
    has_one :shipment
  end

  has_many :products, through: :order_items
end
