module Mapper

  class Sequel

    def self.transaction(&block)
      DB.transaction &block
    end

    def self.create_tables(*entity_classes)
      entity_classes.each do |entity_class|
        table_name = entity_class.to_s.split('::').last.underscore.downcase.pluralize

        DB.create_table(table_name) do
          Mapper::Sequel.schemify(entity_class){ |type,opts| eval("#{type} #{opts}") }
        end
      end
    end

    def self.insert(base_entity, parent_identity={})
      Sequel.check_uow_transaction(base_entity) if parent_identity.empty?  # It's the root
      parent_name = base_entity.class.to_s.split('::').last.underscore.downcase
      parent_table = parent_name.pluralize

      DB.transaction(:rollback=> :reraise) do
        # It's gonna be run as a nested transaction inside the containing UoW
        row = base_entity.to_h.merge(parent_identity)
        row.delete(:id)
        id = DB[parent_table.to_sym].insert(row)
        base_entity.id = id
        unless base_entity.class.child_references.empty?
          base_entity.class.child_references.each do |child|
            parent_identity = {"#{parent_name}_id".to_sym=> id}
            child_attr = base_entity.send(child)
            if child_attr.is_a?(Array)
              unless child_attr.empty?
                child_attr.each do |obj|
                  Sequel.insert_child(obj, parent_identity)
                end
              end
            else
              Sequel.insert_child(child_attr, parent_identity)
            end
          end
        end
        id
      end # transaction
    end

    # TODO: make work the methods below with Aggregate Roots

    def self.delete(base_entity)
      Sequel.check_uow_transaction(base_entity)
      name = base_entity.class.to_s.split('::').last.underscore.downcase
      table = name.pluralize

      DB.transaction(:rollback=> :reraise) do
        DB[table.to_sym].where(id:base_entity.id).delete
      end
    end

    def self.update(base_entity)
      Sequel.check_uow_transaction(base_entity)
      name = base_entity.class.to_s.split('::').last.underscore.downcase
      table = name.pluralize

      DB.transaction(:rollback=> :reraise) do
        row = base_entity.to_h
        DB[table.to_sym].where(id:base_entity.id).update(row)
      end
    end

    def self.reload(base_entity)
      Sequel.check_uow_transaction(base_entity)
      name = base_entity.class.to_s.split('::').last.underscore.downcase
      table = name.pluralize
    end

    private
    def self.check_uow_transaction(base_entity)
      raise RuntimeError, "Invalid Transaction" if base_entity.transactions.empty?
    end

    def self.insert_child(obj, parent_identity)
      Sequel.insert(obj, parent_identity)
    end

    def self.schemify(entity_class)
      entity_class.attributes.each do |attr|
        if entity_class.pk == attr.name
          yield 'primary_key', ":#{attr.name}"
        else
          if attr.is_a?(::BaseEntity::ParentReference)
            yield 'foreign_key', ":#{attr.reference}, :#{attr.name.to_s.pluralize}"
          elsif attr.is_a?(::BaseEntity::Attribute)
            yield "#{attr.type}", ":#{attr.name}"
          end
        end
      end
    end

  end
end