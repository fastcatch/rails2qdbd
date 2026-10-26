# The custom inflection (bonus -> bonuses) makes this resolvable.
class Bonus < ApplicationRecord
  belongs_to :user
end
