# frozen_string_literal: true

require_relative "writer"

module Generator
  # Emits lib/redrain/models/*.rb plus lib/redrain/models.rb, whose require
  # order is topologically sorted so a field can name its type as a bare constant.
  class ModelWriter
    include Writer

    def initialize(root, registry)
      @root = root
      @registry = registry
      @dir = File.join(root, "lib", "redrain", "models")
    end

    def write
      written = []
      @registry.enums.each_value do |definition|
        written << emit(definition.name, enum_source(definition))
      end
      @registry.models.each_value do |definition|
        written << emit(definition.name, model_source(definition))
      end
      prune(@dir, written.map { |p| File.expand_path(p) })
      write_manifest
    end

    private

    def emit(name, source)
      path = File.join(@dir, "#{Naming.snake(name)}.rb")
      write_file(path, source)
      path
    end

    def enum_source(definition)
      body = []
      body.concat(comment(definition.description, indent: "  "))
      body.concat(comment("One of: #{definition.values.join(", ")}", indent: "  "))
      body << "  module #{definition.name}"
      body << "    # @return [Array<String>] every value Rain documents for this field"
      body << "    VALUES = #{literal_array(definition.values)}.freeze"
      body << "  end"
      "#{BANNER}\nmodule Redrain\n#{body.join("\n")}\nend"
    end

    def model_source(definition)
      "#{BANNER}\nmodule Redrain\n#{class_source(definition, "  ")}\nend"
    end

    def class_source(definition, indent, owner: nil)
      lines = []
      lines.concat(comment(definition.description || fallback_description(definition, owner), indent: indent))
      superclass = definition.superclass || "Model"
      lines << "#{indent}class #{definition.name} < #{superclass}"

      inner = indent + "  "
      definition.nested.each do |nested|
        lines << class_source(nested, inner, owner: definition)
        lines << ""
      end

      if definition.discriminator && definition.variants.any?
        lines << "#{inner}# Which variant this record is, read from `#{definition.discriminator}`."
        lines << "#{inner}VARIANTS = #{literal_array(definition.variants)}.freeze"
        lines << ""
      end

      definition.fields.each_with_index do |field, index|
        lines << "" if index.positive?
        lines.concat(field_lines(field, inner))
      end

      lines.concat(predicate_lines(definition, inner))
      lines << "#{indent}end"
      lines.join("\n")
    end

    # Most inline schemas carry no description of their own. Saying which field
    # of which parent they came from beats leaving the class bare.
    def fallback_description(definition, owner)
      return "A #{definition.name} record." unless owner

      "The nested #{definition.name} object carried by #{owner.name}."
    end

    def field_lines(field, indent)
      lines = comment(field.description, indent: indent)
      lines.concat(comment("One of: #{field.enum.join(", ")}", indent: indent)) if field.enum

      # `field` defines the reader at runtime, so YARD needs telling it exists.
      lines << "#{indent}# @!attribute [r] #{field.ruby_name}"
      note = field.required ? " always present in a successful response" : ""
      lines << "#{indent}# @return [#{field.yard_type}, nil]#{note}"

      declaration = +"#{indent}field :#{field.ruby_name}, #{field.type}"
      declaration << %(, api: "#{field.api_name}") if field.api_name != field.ruby_name
      lines << declaration
    end

    def predicate_lines(definition, indent)
      return [] unless definition.discriminator && definition.variants.any?

      lines = [""]
      definition.variants.each do |value|
        lines << %(#{indent}# @return [Boolean] true when `#{definition.discriminator}` is "#{value}")
        lines << %(#{indent}def #{Naming.snake(value)}? = #{Naming.safe_param(definition.discriminator)} == "#{value}")
      end
      lines
    end

    # Depth-first over the dependency graph. Rain's schemas are acyclic; if that
    # ever changes we want a loud failure rather than a NameError at load time.
    def write_manifest
      names = @registry.enums.keys + order(@registry.models)
      requires = names.map { |name| %(require_relative "models/#{Naming.snake(name)}") }
      write_file(
        File.join(@root, "lib", "redrain", "models.rb"),
        "#{BANNER}\n#{requires.join("\n")}"
      )
    end

    def order(models)
      ordered = []
      visiting = []
      visit = lambda do |name|
        return if ordered.include?(name)
        raise "cyclic model dependency: #{(visiting + [name]).join(" -> ")}" if visiting.include?(name)

        visiting.push(name)
        (models[name]&.dependencies || []).each { |dependency| visit.call(dependency) if models.key?(dependency) }
        visiting.pop
        ordered << name
      end
      models.each_key { |name| visit.call(name) }
      ordered
    end
  end
end
