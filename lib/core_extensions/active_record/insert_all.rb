module CoreExtensions
  module ActiveRecord
    module InsertAll

      # The settings of the relation that runs the insert, as `Relation#settings` gives them.
      # Rails 7.1 builds InsertAll from the model inside the relation's `scoping` block, so there
      # the relation is the model's current scope.
      def settings_values
        relation = @relation || model.current_scope
        relation ? relation.settings_values : {}
      end
    end
  end
end
