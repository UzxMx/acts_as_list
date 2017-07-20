module ActiveRecord::Acts::List::CallbackDefiner #:nodoc:
  def self.call(caller_class, position_column, add_new_at)
    caller_class.class_eval do
      before_validation :"check_top_position_for_#{position_column}", unless: :act_as_list_no_update?

      before_destroy :reload, unless: Proc.new { new_record? || send(:"destroyed_via_scope_for_#{position_column}?") || act_as_list_no_update? }
      after_destroy :"decrement_positions_on_lower_items_for_#{position_column}", unless: Proc.new { send(:"destroyed_via_scope_for_#{position_column}?") || act_as_list_no_update? }

      before_update :"check_scope_for_#{position_column}", unless: :act_as_list_no_update?
      after_update :"update_positions_for_#{position_column}", unless: :act_as_list_no_update?

      after_commit :"clear_scope_changed_for_#{position_column}"

      if add_new_at.present?
        before_create "add_to_list_#{add_new_at}_for_#{position_column}".to_sym, unless: :act_as_list_no_update?
      end
    end
  end
end
