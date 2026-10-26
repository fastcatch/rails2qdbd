module Admin
  class AuditLog < ApplicationRecord
    self.table_name = "admin_audit_logs"

    # No database foreign key: this relationship exists only in the model.
    belongs_to :user, optional: true
    belongs_to :subject, class_name: subject_class_name, optional: true
  end
end
