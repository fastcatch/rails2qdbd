# STI: shares the users table.
class StaffUser < User
  has_one_attached :badge
end
