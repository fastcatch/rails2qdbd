class Country < ApplicationRecord
  self.primary_key = "code"

  has_many :addresses, foreign_key: :country_code
end
