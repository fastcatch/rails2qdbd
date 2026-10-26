class Product < ApplicationRecord
  has_and_belongs_to_many :categories
  has_many :order_items
  has_one_attached :photo
  has_many_attached :manuals
end
