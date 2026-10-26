class Membership < ApplicationRecord
  self.primary_key = [:account_id, :user_id]

  belongs_to :account
  belongs_to :user
end
