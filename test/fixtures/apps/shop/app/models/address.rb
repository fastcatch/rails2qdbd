class Address < ApplicationRecord
  belongs_to :addressable, polymorphic: true
  belongs_to :country, foreign_key: :country_code
end
