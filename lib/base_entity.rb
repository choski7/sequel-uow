class IdPk
  PRIMARY_KEY = {:identifier=>:id, :type=>Integer}

  def self.pk
    PRIMARY_KEY[:identifier]
  end
end

class BaseEntity < IdPk
  extend Repository::Sequel::ClassFinders
  include Repository::Sequel::InstanceFinders
  extend UnitOfWork::TransactionRegistry::FinderService::ClassMethods
  include UnitOfWork::TransactionRegistry::FinderService::InstanceMethods

  private

  class Attribute
    attr_reader :name, :type, :default
    def initialize(name, type, mandatory=false, default=nil)
      # TODO validate entry
      @name = name
      @type = type
      @mandatory = mandatory
      @default = default
    end
    def check_constraints(value)  # check invariant constraints, called by setter
      raise RuntimeError, "#{@name} must be defined" if @mandatory && value.nil?
      raise RuntimeError, "#{@name} must be a #{@type} - got: #{value.class}" unless value.nil? || value.is_a?(@type)
    end
  end

  class Reference
    attr_reader :name, :type, :reference
    def initialize(name)
      @name = name
      @type = BaseEntity
      @reference = "#{name.to_s.singularize}_id".to_sym
    end
    def check_constraints(value)  # check invariant constraints, called by setter
      raise RuntimeError, "#{@name} must be a #{@type}" unless value.nil? || value.is_a?(@type)
    end
  end

  class ParentReference < Reference
    def initialize(name)
      super(name)
    end
    def default
      nil  # pass by value
    end
  end

  class ChildReference < Reference
    def initialize(name)
      super(name)
    end
    def default
      Array.new # pass by value
    end
  end


  public

  def self.inherited(base)
    base.class_variable_set(:'@@attributes',{PRIMARY_KEY[:identifier]=>Attribute.new(
        PRIMARY_KEY[:identifier], PRIMARY_KEY[:type])})
    base.attach_attribute_accessors(PRIMARY_KEY[:identifier])
    base.instance_eval do
      def attributes
        self.class_variable_get(:'@@attributes').values
      end
    end
  end

  def self.children(*names)
    names.each do |child|
      self.class_variable_get(:'@@attributes')[child] =  ChildReference.new(child)
      self.attach_attribute_accessors(child, :aggregate)
      self.define_aggregate_method(child)
    end
  end

  def self.parents(*names)
    names.each do |parent|
      self.class_variable_get(:'@@attributes')[parent] =  ParentReference.new(parent)
      self.attach_attribute_accessors(parent, :parent)
    end
  end

  def self.attribute(name, type, *opts)
    parsed_opts = opts.reduce({}){|m,opt| m.merge!(opt); m }
    self.class_variable_get(:'@@attributes')[name] =  Attribute.new(
        name, type, parsed_opts[:mandatory], parsed_opts[:default])
    self.attach_attribute_accessors(name)
  end

  def initialize(in_h={}, parent=nil)
    # TODO check in_h is_a? Hash
    self.class.class_variable_get(:'@@attributes').each do |k,v|
      instance_variable_set("@#{k}".to_sym, v.default)
    end
    unless parent.nil?
      parent_attr = parent.class.to_s.split('::').last.underscore.downcase
      instance_variable_set("@#{parent_attr}".to_sym, parent)
    end
    load_attributes(in_h) unless in_h.empty?
  end

  def make(in_h)
    load_attributes(in_h)
  end

  def destroy
    if defined?(self.class::CHILDREN) and self.class::CHILDREN.is_a?(Array) and !self.class::CHILDREN.empty?
      self.class::CHILDREN.each do |child|
        send("destroy_#{child}".to_sym)
      end
    else
      #@metadata.mark_for_deletion unless @id.nil?
    end
  end

  def to_h
    h = {}
    instance_variables.each do |attr|
      attr_name = attr.to_s[1..-1].to_sym
      attr_value = instance_variable_get(attr)
      h[attr_name] =  attr_value unless attr_value.is_a?(BaseEntity) || attr_value.is_a?(Array)
    end
    h
  end


  def self.child_references
    attrs = self.attributes
    refs = attrs.reduce([]){|m,attr| attr.is_a?(ChildReference) ? m<<attr.name : m }
    refs
  end

  # TODO:
  #def eql?
  #end
  #alias_method :==, :eql?

  private
  protected

  def self.attach_attribute_accessors(name, type=:plain)
    self.class_eval do
      define_method(name){instance_variable_get("@#{name}".to_sym)}
      if :plain == type
        define_method("#{name}="){ |new_value|
          self.class.class_variable_get(:'@@attributes')[name].check_constraints(new_value)
          instance_variable_set("@#{name}".to_sym, new_value)
        }
      elsif :aggregate == type
        define_method("#{name}<<"){ |new_value|
          instance_variable_get("@#{name}".to_sym)<< new_value
        }
      end
    end
  end

  # TODO: check_reserved_keys(in_h) => :metadata

  def load_attributes(in_h)
    aggregates = {}

    in_h.each do |k,v|
      attr_obj = self.class.class_variable_get(:'@@attributes')[k]
      if attr_obj.is_a?(Attribute)
        send("#{k}=".to_sym, v)
      else
        aggregates[k] = v
      end
    end

    (aggregates.each do |k,v|
      send("make_#{k}".to_sym, v)
    end) unless aggregates.empty?
  end

  def self.define_aggregate_method(child)
    self.class_eval do

      # Single-entity methods:

      define_method("make_#{child.to_s.singularize}".to_sym) do |in_h|
        a_child = Object.const_get(child.to_s.singularize.camelize).new(in_h, self)
        send("#{child}<<".to_sym, a_child)
        a_child
      end

      # Collection methods:

      define_method("make_#{child}".to_sym) do |in_a|
        children = []
        in_a.each {|in_h| children<< send("make_#{child.to_s.singularize}".to_sym, in_h)}
        children
      end

      define_method("destroy_#{child}".to_sym) do
        instance_variable_get("@#{child}".to_sym).each do |obj|
          obj.destroy
        end
      end
    end
  end

end