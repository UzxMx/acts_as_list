module ActiveRecord::Acts::List::ScopeMethodDefiner #:nodoc:
  extend ActiveSupport::Inflector

  def self.call(caller_class, position_column, scope)
    scope = idify(scope) if scope.is_a?(Symbol)

    caller_class.class_eval do
      define_method :"scope_name_for_#{position_column}" do
        scope
      end

      if scope.is_a?(Symbol)
        define_method :"scope_condition_for_#{position_column}" do
          { scope => send(:"#{scope}") }
        end

        define_method :"scope_changed_for_#{position_column}?" do
          changed.include?(send(:"scope_name_for_#{position_column}").to_s)
        end

        define_method :"destroyed_via_scope_for_#{position_column}?" do
          return false if ActiveRecord::VERSION::MAJOR < 4
          scope == (destroyed_by_association && destroyed_by_association.foreign_key.to_sym)
        end
      elsif scope.is_a?(Array)
        define_method :"scope_condition_for_#{position_column}" do
          scope.inject({}) do |hash, column|
            hash.merge!({ column.to_sym => read_attribute(column.to_sym) })
          end
        end

        define_method :"scope_changed_for_#{position_column}?" do
          (send(:"scope_condition_for_#{position_column}").keys & changed.map(&:to_sym)).any?
        end

        define_method :"destroyed_via_scope_for_#{position_column}?" do
          return false if ActiveRecord::VERSION::MAJOR < 4
          send(:"scope_condition_for_#{position_column}").keys.include? (destroyed_by_association && destroyed_by_association.foreign_key.to_sym)
        end
      else
        define_method :"scope_condition_for_#{position_column}" do
          eval "%{#{scope}}"
        end

        define_method :"scope_changed_for_#{position_column}?" do
          false
        end

        define_method :"destroyed_via_scope_for_#{position_column}?" do
          false
        end
      end

      self.scope :"in_list_for_#{position_column}", lambda { where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} IS NOT NULL") }
    end
  end

  def self.idify(name)
    return name if name.to_s =~ /_id$/

    foreign_key(name).to_sym
  end
end
