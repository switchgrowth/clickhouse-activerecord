module CoreExtensions
  module ActiveRecord
    module InsertAll
      module Builder
        def initialize(insert_all)
          super
        end

        def settings_list
          settings = insert_all.relation.values.fetch(:settings, {})
          connection.visitor.compile(::Arel::Nodes::Settings.new(settings))
        end
      end
    end
  end
end