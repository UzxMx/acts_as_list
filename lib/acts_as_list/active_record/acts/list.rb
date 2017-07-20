module ActiveRecord
  module Acts #:nodoc:
    module List #:nodoc:

      module ClassMethods
        # Configuration options are:
        #
        # * +column+ - specifies the column name to use for keeping the position integer (default: +position+)
        # * +scope+ - restricts what is to be considered a list. Given a symbol, it'll attach <tt>_id</tt>
        #   (if it hasn't already been added) and use that as the foreign key restriction. It's also possible
        #   to give it an entire string that is interpolated if you need a tighter scope than just a foreign key.
        #   Example: <tt>acts_as_list scope: 'todo_list_id = #{todo_list_id} AND completed = 0'</tt>
        # * +top_of_list+ - defines the integer used for the top of the list. Defaults to 1. Use 0 to make the collection
        #   act more like an array in its indexing.
        # * +add_new_at+ - specifies whether objects get added to the :top or :bottom of the list. (default: +bottom+)
        #                   `nil` will result in new items not being added to the list on create.
        # * +sequential_updates+ - specifies whether insert_at should update objects positions during shuffling
        #   one by one to respect position column unique not null constraint.
        #   Defaults to true if position column has unique index, otherwise false.
        #   If constraint is <tt>deferrable initially deferred<tt>, overriding it with false will speed up insert_at.
        def acts_as_list(options = {})
          configuration = { column: "position", scope: "1 = 1", top_of_list: 1, add_new_at: :bottom }
          configuration.update(options) if options.is_a?(Hash)

          caller_class = self

          ActiveRecord::Acts::List::PositionColumnMethodDefiner.call(caller_class, configuration[:column])
          ActiveRecord::Acts::List::ScopeMethodDefiner.call(caller_class, configuration[:column], configuration[:scope])
          ActiveRecord::Acts::List::TopOfListMethodDefiner.call(caller_class, configuration[:top_of_list])
          ActiveRecord::Acts::List::AddNewAtMethodDefiner.call(caller_class, configuration[:add_new_at])

          ActiveRecord::Acts::List::AuxMethodDefiner.call(caller_class)
          ActiveRecord::Acts::List::CallbackDefiner.call(caller_class, configuration[:column], configuration[:add_new_at])
          ActiveRecord::Acts::List::SequentialUpdatesMethodDefiner.call(caller_class, configuration[:column], configuration[:sequential_updates])
          ActiveRecord::Acts::List::InstanceMethodDefiner.call(caller_class, configuration[:column])

          include ActiveRecord::Acts::List::InstanceMethods
          include ActiveRecord::Acts::List::NoUpdate
        end

        # This +acts_as+ extension provides the capabilities for sorting and reordering a number of objects in a list.
        # The class that has this specified needs to have a +position+ column defined as an integer on
        # the mapped database table.
        #
        # Todo list example:
        #
        #   class TodoList < ActiveRecord::Base
        #     has_many :todo_items, order: "position"
        #   end
        #
        #   class TodoItem < ActiveRecord::Base
        #     belongs_to :todo_list
        #     acts_as_list scope: :todo_list
        #   end
        #
        #   todo_list.first.move_to_bottom
        #   todo_list.last.move_higher

        # All the methods available to a record that has had <tt>acts_as_list</tt> specified. Each method works
        # by assuming the object to be the item in the list, so <tt>chapter.move_lower</tt> would move that chapter
        # lower in the list of all chapters. Likewise, <tt>chapter.first?</tt> would return +true+ if that chapter is
        # the first in the list of all chapters.
      end

      module InstanceMethodDefiner
        def self.call(caller_class, position_column)
          caller_class.class_eval do

            define_method :"acts_as_list_list_for_#{position_column}" do
              if ActiveRecord::VERSION::MAJOR < 4
                acts_as_list_class.unscoped do
                  acts_as_list_class.where(send(:"scope_condition_for_#{position_column}"))
                end
              else
                acts_as_list_class.unscope(:where).where(send(:"scope_condition_for_#{position_column}"))
              end
            end

            define_method :"internal_scope_changed_for_#{position_column}?" do
              sym = :"@scope_changed_for_#{position_column}"
              return instance_variable_get(sym) if instance_variable_defined?(sym)

              instance_variable_set(sym, send(:"scope_changed_for_#{position_column}?"))
            end

            define_method :"clear_scope_changed_for_#{position_column}" do
              sym = :"@scope_changed_for_#{position_column}"
              remove_instance_variable(sym) if instance_variable_defined?(sym)
            end

            define_method :"check_scope_for_#{position_column}" do
              if send(:"internal_scope_changed_for_#{position_column}?")
                cached_changes = changes

                cached_changes.each { |attribute, values| send("#{attribute}=", values[0]) }
                send(:"decrement_positions_on_lower_items_for_#{position_column}") if send(:"lower_item_for_#{position_column}")
                cached_changes.each { |attribute, values| send("#{attribute}=", values[1]) }

                send(:"add_to_list_#{add_new_at}_for_#{position_column}") if add_new_at.present?
              end
            end            

            # Returns the bottom position number in the list.
            #   bottom_position_in_list    # => 2
            define_method :"bottom_position_in_list_for_#{position_column}" do |except = nil|
              item = send(:"bottom_item_for_#{position_column}", except)
              item ? item.send(position_column) : acts_as_list_top - 1
            end

            # Returns the bottom item
            define_method :"bottom_item_for_#{position_column}" do |except = nil|
              scope = send(:"acts_as_list_list_for_#{position_column}")

              if except
                scope = scope.where("#{quoted_table_name}.#{self.class.primary_key} != ?", except.id)
              end

              scope.send(:"in_list_for_#{position_column}").reorder("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} DESC").first
            end

            # Forces item to assume the bottom position in the list.
            define_method :"assume_bottom_position_for_#{position_column}" do
              send :"set_list_position_for_#{position_column}", send(:"bottom_position_in_list_for_#{position_column}", self).to_i + 1
            end

            # Forces item to assume the top position in the list.
            define_method :"assume_top_position_for_#{position_column}" do
              send :"set_list_position_for_#{position_column}", acts_as_list_top
            end

            define_method :"update_positions_for_#{position_column}" do
              old_position = send(:"position_before_save_for_#{position_column}") || send(:"bottom_position_in_list_for_#{position_column}") + 1
              new_position = send(position_column).to_i

              return unless send(:"acts_as_list_list_for_#{position_column}").where(
                "#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} = #{new_position}"
              ).count > 1
              send :"shuffle_positions_on_intermediate_items_for_#{position_column}", old_position, new_position, id
            end

            define_method :"position_before_save_for_#{position_column}" do
              if ActiveRecord::VERSION::MAJOR == 5 && ActiveRecord::VERSION::MINOR >= 1 ||
                  ActiveRecord::VERSION::MAJOR > 5

                send("#{position_column}_before_last_save")
              else
                send("#{position_column}_was")
              end
            end            

            # should be private methods
            define_method :"swap_positions_for_#{position_column}" do |item1, item2|
              item1_position = item1.send(position_column)

              item1.send(:"set_list_position_for_#{position_column}", item2.send(position_column))
              item2.send(:"set_list_position_for_#{position_column}", item1_position)
            end            

            # Insert the item at the given position (defaults to the top position of 1).
            define_method :"insert_at_for_#{position_column}" do |position = acts_as_list_top|
              send :"insert_at_position_for_#{position_column}", position
            end

            # Swap positions with the next lower item, if one exists.
            define_method :"move_lower_for_#{position_column}" do
              return unless send(:"lower_item_for_#{position_column}")

              acts_as_list_class.transaction do
                if send(:"lower_item_for_#{position_column}").send(position_column) != self.send(position_column)
                  send :"swap_positions_for_#{position_column}", send(:"lower_item_for_#{position_column}"), self
                else
                  send(:"lower_item_for_#{position_column}").send(:"decrement_position_for_#{position_column}")
                  send(:"increment_position_for_#{position_column}")
                end
              end              
            end

            # Swap positions with the next higher item, if one exists.
            define_method :"move_higher_for_#{position_column}" do
              return unless send(:"higher_item_for_#{position_column}")

              acts_as_list_class.transaction do
                if send(:"higher_item_for_#{position_column}").send(position_column) != self.send(position_column)
                  send :"swap_positions_for_#{position_column}", send(:"higher_item_for_#{position_column}"), self
                else
                  send(:"higher_item_for_#{position_column}").send(:"increment_position_for_#{position_column}")
                  send(:"decrement_position_for_#{position_column}")
                end
              end
            end

            # Move to the bottom of the list. If the item is already in the list, the items below it have their
            # position adjusted accordingly.
            define_method :"move_to_bottom_for_#{position_column}" do
              return unless send(:"in_list_for_#{position_column}?")
              acts_as_list_class.transaction do
                send(:"decrement_positions_on_lower_items_for_#{position_column}")
                send :"assume_bottom_position_for_#{position_column}"
              end
            end

            # Move to the top of the list. If the item is already in the list, the items above it have their
            # position adjusted accordingly.
            define_method :"move_to_top_for_#{position_column}" do
              return unless send(:"in_list_for_#{position_column}?")
              acts_as_list_class.transaction do
                send :"increment_positions_on_higher_items_for_#{position_column}"
                send :"assume_top_position_for_#{position_column}"
              end
            end

            # Removes the item from the list.
            define_method :"remove_from_list_for_#{position_column}" do
              if send(:"in_list_for_#{position_column}?")
                send(:"decrement_positions_on_lower_items_for_#{position_column}")
                send :"set_list_position_for_#{position_column}", nil
              end
            end            

            # Increase the position of this item without adjusting the rest of the list.
            define_method :"increment_position_for_#{position_column}" do
              return unless send(:"in_list_for_#{position_column}?")
              send :"set_list_position_for_#{position_column}", self.send(position_column).to_i + 1
            end

            # Decrease the position of this item without adjusting the rest of the list.
            define_method :"decrement_position_for_#{position_column}" do
              return unless send(:"in_list_for_#{position_column}?")
              send :"set_list_position_for_#{position_column}", self.send(position_column).to_i - 1
            end

            define_method :"first_for_#{position_column}?" do
              return false unless send(:"in_list_for_#{position_column}?")
              !send(:"higher_items_for_#{position_column}", 1).exists?
            end

            define_method :"last_for_#{position_column}?" do
              return false unless send(:"in_list_for_#{position_column}?")
              !send(:"lower_items_for_#{position_column}", 1).exists?
            end

            # Return the next higher item in the list.
            define_method :"higher_item_for_#{position_column}" do
              return nil unless send(:"in_list_for_#{position_column}?")
              send(:"higher_items_for_#{position_column}", 1).first
            end

            # Return the next n higher items in the list
            # selects all higher items by default
            define_method :"higher_items_for_#{position_column}" do |limit=nil|
              limit ||= send(:"acts_as_list_list_for_#{position_column}").count
              position_value = send(position_column)
              send(:"acts_as_list_list_for_#{position_column}").
                where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} <= ?", position_value).
                where("#{quoted_table_name}.#{self.class.primary_key} != ?", self.send(self.class.primary_key)).
                reorder("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} DESC").
                limit(limit)
            end

            # Return the next lower item in the list.
            define_method :"lower_item_for_#{position_column}" do
              return nil unless send(:"in_list_for_#{position_column}?")
              send(:"lower_items_for_#{position_column}", 1).first
            end

            # Return the next n lower items in the list
            # selects all lower items by default
            define_method :"lower_items_for_#{position_column}" do |limit=nil|
              limit ||= send(:"acts_as_list_list_for_#{position_column}").count
              position_value = send(position_column)
              send(:"acts_as_list_list_for_#{position_column}").
                where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} >= ?", position_value).
                where("#{quoted_table_name}.#{self.class.primary_key} != ?", self.send(self.class.primary_key)).
                reorder("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} ASC").
                limit(limit)
            end

            # Sets the new position and saves it
            define_method :"set_list_position_for_#{position_column}" do |new_position|
              write_attribute position_column, new_position
              save(validate: false)
            end

            # Test if this record is in a list
            define_method :"in_list_for_#{position_column}?" do
              !send(:"not_in_list_for_#{position_column}?")
            end

            define_method :"not_in_list_for_#{position_column}?" do
              send(position_column).nil?
            end

            # This has the effect of moving all the higher items down one.
            define_method :"increment_positions_on_higher_items_for_#{position_column}" do
              return unless send(:"in_list_for_#{position_column}?")
              send(:"acts_as_list_list_for_#{position_column}").where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} < ?", send(position_column).to_i).send(:"increment_all_for_#{position_column}")
            end

            # This has the effect of moving all the lower items down one.
            define_method :"increment_positions_on_lower_items_for_#{position_column}" do |position, avoid_id = nil|
              scope = send(:"acts_as_list_list_for_#{position_column}")

              if avoid_id
                scope = scope.where("#{quoted_table_name}.#{self.class.primary_key} != ?", avoid_id)
              end

              scope.where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} >= ?", position).send(:"increment_all_for_#{position_column}")
            end

            # This has the effect of moving all the higher items up one.
            define_method :"decrement_positions_on_higher_items_for_#{position_column}" do |position|
              send(:"acts_as_list_list_for_#{position_column}").where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} <= ?", position).send(:"decrement_all_for_#{position_column}")
            end

            # This has the effect of moving all the lower items up one.
            define_method :"decrement_positions_on_lower_items_for_#{position_column}" do |position=nil|
              return unless send(:"in_list_for_#{position_column}?")
              position ||= send(position_column).to_i
              send(:"acts_as_list_list_for_#{position_column}").where("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} > ?", position).send(:"decrement_all_for_#{position_column}")
            end

            # Increments position (<tt>position_column</tt>) of all items in the list.
            define_method :"increment_positions_on_all_items_for_#{position_column}" do
              send(:"acts_as_list_list_for_#{position_column}").send(:"increment_all_for_#{position_column}")
            end

            # Reorders intermediate items to support moving an item from old_position to new_position.
            # unique constraint prevents regular increment_all and forces to do increments one by one
            # http://stackoverflow.com/questions/7703196/sqlite-increment-unique-integer-field
            # both SQLite and PostgreSQL (and most probably MySQL too) has same issue
            # that's why *sequential_updates?* check alters implementation behavior
            define_method :"shuffle_positions_on_intermediate_items_for_#{position_column}" do |old_position, new_position, avoid_id = nil|
              return if old_position == new_position
              scope = send(:"acts_as_list_list_for_#{position_column}")

              if avoid_id
                scope = scope.where("#{quoted_table_name}.#{self.class.primary_key} != ?", avoid_id)
              end

              if old_position < new_position
                # Decrement position of intermediate items
                #
                # e.g., if moving an item from 2 to 5,
                # move [3, 4, 5] to [2, 3, 4]
                items = scope.where(
                  "#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} > ?", old_position
                ).where(
                  "#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} <= ?", new_position
                )

                if send(:"sequential_updates_for_#{position_column}?")
                  items.reorder("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} ASC").each do |item|
                    item.decrement!(position_column)
                  end
                else
                  items.send(:"decrement_all_for_#{position_column}")
                end
              else
                # Increment position of intermediate items
                #
                # e.g., if moving an item from 5 to 2,
                # move [2, 3, 4] to [3, 4, 5]
                items = scope.where(
                  "#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} >= ?", new_position
                ).where(
                  "#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} < ?", old_position
                )

                if send(:"sequential_updates_for_#{position_column}?")
                  items.reorder("#{send(:"quoted_position_column_with_table_name_for_#{position_column}")} DESC").each do |item|
                    item.increment!(position_column)
                  end
                else
                  items.send(:"increment_all_for_#{position_column}")
                end
              end
            end

            define_method :"insert_at_position_for_#{position_column}" do |postion|
              return send(:"set_list_position_for_#{position_column}", position) if new_record?
              with_lock do
                if send(:"in_list_for_#{position_column}?")
                  old_position = send(position_column).to_i
                  return if position == old_position
                  # temporary move after bottom with gap, avoiding duplicate values
                  # gap is required to leave room for position increments
                  # positive number will be valid with unique not null check (>= 0) db constraint
                  temporary_position = send(:"bottom_position_in_list_for_#{position_column}") + 2
                  send(:"set_list_position_for_#{position_column}", temporary_position)
                  send :"shuffle_positions_on_intermediate_items_for_#{position_column}", old_position, position, id
                else
                  send :"increment_positions_on_lower_items_for_#{position_column}", position
                end
                send(:"set_list_position_for_#{position_column}", position)
              end
            end

            # Poorly named methods. They will insert the item at the desired position if the position
            # has been set manually using position=, not necessarily the top or bottom of the list:
            define_method :"add_to_list_top_for_#{position_column}" do
              if send(:"not_in_list_for_#{position_column}?") || send(:"internal_scope_changed_for_#{position_column}?") && !send(:"position_changed_for_#{position_column}") || send(:"default_position_for_#{position_column}?")
                send :"increment_positions_on_all_items_for_#{position_column}"
                self[position_column] = acts_as_list_top
              else
                send :"increment_positions_on_lower_items_for_#{position_column}", self[position_column], id
              end

              # Make sure we know that we've processed this scope change already
              instance_variable_set :"@scope_changed_for_#{position_column}", false

              # Don't halt the callback chain
              true
            end

            define_method :"add_to_list_bottom_for_#{position_column}" do
              if send(:"not_in_list_for_#{position_column}?") || send(:"internal_scope_changed_for_#{position_column}?") && !send(:"position_changed_for_#{position_column}") || send(:"default_position_for_#{position_column}?")
                self[position_column] = send(:"bottom_position_in_list_for_#{position_column}").to_i + 1
              else
                send :"increment_positions_on_lower_items_for_#{position_column}", self[position_column], id
              end

              # Make sure we know that we've processed this scope change already
              instance_variable_set :"@scope_changed_for_#{position_column}", false

              # Don't halt the callback chain
              true              
            end

            define_method :"default_position_for_#{position_column}" do
              acts_as_list_class.columns_hash[send(:"position_column_for_#{position_column}").to_s].default
            end

            define_method :"default_position_for_#{position_column}?" do
              default_position = send(:"default_position_for_#{position_column}")
              default_position && default_position.to_i == send(:"position_column_for_#{position_column}")
            end

            # This check is skipped if the position is currently the default position from the table
            # as modifying the default position on creation is handled elsewhere
            define_method :"check_top_position_for_#{position_column}" do
              if send(:"position_column_for_#{position_column}") && !send(:"default_position_for_#{position_column}?") && (position = send(position_column)) && position < acts_as_list_top
                self[position_column] = acts_as_list_top
              end
            end
          end
        end
      end

      module InstanceMethods
        # Move the item within scope. If a position within the new scope isn't supplied, the item will
        # be appended to the end of the list.
        def move_within_scope(scope_id)
          send("#{scope_name}=", scope_id)
          save!
        end

        private

        # Used in order clauses
        def quoted_table_name
          @_quoted_table_name ||= acts_as_list_class.quoted_table_name
        end        
      end
    end
  end
end
