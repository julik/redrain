# frozen_string_literal: true

module Generator
  # Thin read model over the OpenAPI document: $ref resolution, allOf flattening,
  # and a route index keyed the same way dev/resource_map.yml is.
  class Spec
    def self.load(path) = new(JSON.parse(File.read(path)))

    def initialize(doc)
      @doc = doc
    end

    attr_reader :doc

    def schemas = @doc.dig("components", "schemas")

    # "GET /cards" => operation hash
    def routes
      @routes ||= @doc["paths"].each_with_object({}) do |(path, methods), out|
        methods.each { |verb, op| out["#{verb.upcase} #{path}"] = op.merge("path" => path, "verb" => verb.upcase) }
      end
    end

    def deref(node)
      return node unless node.is_a?(Hash) && node["$ref"]

      pointer = node["$ref"].delete_prefix("#/").split("/")
      @doc.dig(*pointer) or raise "unresolvable $ref #{node["$ref"]}"
    end

    def ref_name(node)
      return nil unless node.is_a?(Hash) && node["$ref"]&.start_with?("#/components/schemas/")

      node["$ref"].split("/").last
    end

    # Collapses allOf into a single object schema, remembering which component
    # was referenced so the model builder can turn it into a Ruby superclass.
    # Returns [flattened_schema, superclass_name_or_nil].
    def flatten(schema)
      return [schema, nil] unless schema.is_a?(Hash) && schema["allOf"]

      superclass = nil
      merged = { "type" => "object", "properties" => {}, "required" => [] }
      merged["description"] = schema["description"] if schema["description"]

      schema["allOf"].each do |member|
        if (name = ref_name(member))
          # First named member becomes the superclass; any further ones get
          # merged in flat, since Ruby has no multiple inheritance.
          if superclass.nil?
            superclass = name
            next
          end
          member = deref(member)
        end
        member, = flatten(member)
        merged["properties"].merge!(member["properties"] || {})
        merged["required"] |= (member["required"] || [])
      end

      [merged, superclass]
    end

    # Merges oneOf variants into one permissive schema. Rain's two unions are
    # discriminated families that share a key ("type", "status"), so a single
    # class with predicate helpers beats a Ruby union type nobody can pattern-match.
    # Returns [merged_schema, discriminator_property_or_nil, variant_values].
    def flatten_one_of(schema)
      return [schema, nil, []] unless schema.is_a?(Hash) && schema["oneOf"]

      variants = schema["oneOf"].map { |v| flatten(deref(v)).first }
      discriminator = schema.dig("discriminator", "propertyName") || infer_discriminator(variants)

      merged = { "type" => "object", "properties" => {}, "required" => [] }
      merged["description"] = schema["description"] if schema["description"]
      # Only what every variant guarantees stays required.
      common_required = variants.map { |v| v["required"] || [] }.reduce(:&) || []

      variants.each { |v| merged["properties"].merge!(v["properties"] || {}) }
      merged["required"] = common_required
      drop_conflicting_descriptions!(merged, variants)

      values = discriminator ? discriminator_values(variants, discriminator) : []
      if discriminator && values.any?
        # Each variant describes the discriminator from its own point of view
        # ("in this case, a fee transaction"), and merging leaves whichever came
        # last. Replace it with the union so the generated docs list every value.
        merged["properties"][discriminator] = {
          "type" => "string",
          "enum" => values,
          "description" => "Which kind of record this is, and therefore which of the detail fields is populated"
        }
      end

      [merged, discriminator, values]
    end

    private

    # A shared property described differently by each variant ("the identifier of
    # the fee transaction" vs "...of the spend transaction") would otherwise
    # inherit whichever variant merged last, which reads as a plain error.
    def drop_conflicting_descriptions!(merged, variants)
      merged["properties"].each_key do |name|
        descriptions = variants.filter_map { |v| v.dig("properties", name, "description") }.uniq
        merged["properties"][name] = merged["properties"][name].reject { |k, _| k == "description" } if descriptions.size > 1
      end
    end

    # A property that every variant requires and pins to a single enum value is
    # the discriminator, whether or not the spec says so.
    def infer_discriminator(variants)
      candidates = variants.map { |v| (v["properties"] || {}).keys }.reduce(:&) || []
      candidates.find do |name|
        variants.all? { |v| (v.dig("properties", name, "enum") || []).size == 1 }
      end
    end

    def discriminator_values(variants, property)
      variants.filter_map { |v| (v.dig("properties", property, "enum") || []).first }.uniq
    end
  end
end
