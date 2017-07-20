module ActiveRecord::Acts::List::SequentialUpdatesMethodDefiner #:nodoc:
  def self.call(caller_class, column, sequential_updates_option)
    caller_class.class_eval do
      define_method :"sequential_updates_for_#{column}?" do
        if !instance_variable_defined?(:"@sequential_updates_for_#{column}")
          if sequential_updates_option.nil?
            table_exists =
              if ActiveRecord::VERSION::MAJOR >= 5
                caller_class.connection.data_source_exists?(caller_class.table_name)
              else
                caller_class.connection.table_exists?(caller_class.table_name)
              end
            index_exists = caller_class.connection.index_exists?(caller_class.table_name, column, unique: true)
            instance_variable_set :"@sequential_updates_for_#{column}", table_exists && index_exists
          else
            instance_variable_set :"@sequential_updates_for_#{column}", sequential_updates_option
          end
        else
          instance_variable_get :"@sequential_updates_for_#{column}"
        end
      end

      private :"sequential_updates_for_#{column}?"
    end
  end
end
