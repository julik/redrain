# frozen_string_literal: true

module Generator
  # Turns OpenAPI schemas into model definitions and remembers them by name.
  # Response schemas that are only reachable through an operation get defined
  # here too, by ResourceBuilder calling #define.
  class Registry
    Field = Struct.new(:ruby_name, :api_name, :type, :description, :required, :enum, keyword_init: true) do
      # The declared type expressed as YARD writes it, for @return tags.
      def yard_type = Naming.yard_type(type)
    end

    ModelDef = Struct.new(
      :name, :superclass, :description, :fields, :nested,
      :discriminator, :variants, :dependencies,
      keyword_init: true
    )

    EnumDef = Struct.new(:name, :description, :values, keyword_init: true)

    PRIMITIVES = {
      "integer" => ":integer",
      "number"  => ":number",
      "boolean" => ":boolean"
    }.freeze

    def initialize(spec)
      @spec = spec
      @models = {}
      @enums  = {}
    end

    attr_reader :models, :enums

    # Every named component becomes either a model class or, for bare string
    # enums, a module of allowed values.
    def load_components!
      @spec.schemas.each_key { |name| component(name) }
    end

    def component(name)
      return @models[name] || @enums[name] if @models.key?(name) || @enums.key?(name)

      schema = @spec.schemas.fetch(name)
      if enum_only?(schema)
        @enums[name] = EnumDef.new(name: name, description: schema["description"], values: schema["enum"])
      else
        define(name, schema)
      end
    end

    # Defines a top-level model from a schema. Returns the ModelDef.
    def define(name, schema)
      # Placeholder first: a schema that refers back to its own component would
      # otherwise recurse forever.
      @models[name] = nil
      @models[name] = build_model(name, schema)
    end

    # Ruby type expression for a schema, in the context of a model that nested
    # classes get attached to.
    def type_for(schema, owner, hint)
      schema = schema || {}

      if (ref = @spec.ref_name(schema))
        target = component(ref)
        return ":string" if target.is_a?(EnumDef)

        owner.dependencies << ref
        return ref
      end

      schema = @spec.deref(schema)
      schema, superclass = @spec.flatten(schema) if schema["allOf"]
      if superclass
        owner.dependencies << superclass
        # An inline allOf that only extends a component and adds nothing is just
        # that component.
        return superclass if (schema["properties"] || {}).empty?
      end
      schema, = @spec.flatten_one_of(schema) if schema["oneOf"]

      case schema["type"]
      when "array"
        "[#{type_for(schema["items"], owner, Naming.singular(hint))}]"
      when "string"
        schema["format"] == "date-time" ? ":time" : ":string"
      when "object", nil
        object_type(schema, owner, hint, superclass)
      else
        PRIMITIVES.fetch(schema["type"], ":object")
      end
    end

    private

    def object_type(schema, owner, hint, superclass)
      properties = schema["properties"] || {}
      # A free-form object with no declared shape stays a plain Hash — inventing
      # an empty class for it would help nobody.
      return ":object" if properties.empty? && superclass.nil?

      base = Naming.pascal(hint)
      nested = build_model(base, schema, container: owner)

      # Two properties in the same model can share a name ("address" on both the
      # company and its representative). Identical shapes collapse to one class;
      # genuinely different ones get numbered rather than silently clobbering.
      siblings = owner.nested.select { |n| n.name == base || n.name.match?(/\A#{base}\d+\z/) }
      twin = siblings.find { |n| n.fields.map(&:api_name) == nested.fields.map(&:api_name) }
      # Bare constant, not owner-qualified: nested classes are emitted above the
      # fields that name them, so lexical scope resolves it.
      return twin.name if twin

      nested.name = siblings.empty? ? base : "#{base}#{siblings.size + 1}"
      owner.nested << nested
      nested.name
    end

    def build_model(name, schema, container: nil)
      schema, superclass = @spec.flatten(schema)
      schema, discriminator, variants = @spec.flatten_one_of(schema)

      model = ModelDef.new(
        name: name,
        superclass: superclass,
        description: schema["description"],
        fields: [],
        nested: [],
        discriminator: discriminator,
        variants: variants,
        dependencies: []
      )
      (container || model).dependencies << superclass if superclass

      required = schema["required"] || []
      (schema["properties"] || {}).each do |api_name, property|
        property = @spec.deref(property) if property["$ref"] && !@spec.ref_name(property)
        model.fields << Field.new(
          ruby_name: Naming.safe_param(api_name),
          api_name: api_name,
          # Nested classes hang off the outermost model, so their constant paths
          # stay flat rather than nesting three deep.
          type: type_for(property, container || model, api_name),
          description: property.is_a?(Hash) ? property["description"] : nil,
          required: required.include?(api_name),
          enum: property.is_a?(Hash) ? (property["enum"] || enum_values_of_ref(property)) : nil
        )
      end

      # Nested classes built against a container were appended there already.
      model.dependencies.uniq!
      model.dependencies.delete(name)
      model
    end

    def enum_values_of_ref(property)
      ref = @spec.ref_name(property)
      return nil unless ref

      target = component(ref)
      target.is_a?(EnumDef) ? target.values : nil
    end

    def enum_only?(schema)
      schema["enum"] && schema["type"] == "string" && schema["properties"].nil?
    end
  end
end
