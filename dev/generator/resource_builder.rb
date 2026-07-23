# frozen_string_literal: true

module Generator
  # Walks dev/resource_map.yml, pairing each route with its spec operation to
  # produce a tree of resource definitions with fully-typed method signatures.
  class ResourceBuilder
    Param = Struct.new(:ruby_name, :api_name, :description, :required, :enum, :kind, :yard_type,
      keyword_init: true)

    Method = Struct.new(
      :name, :verb, :path, :summary, :description,
      :positional, :params, :returns, :binary, :multipart,
      keyword_init: true
    )

    ResourceDef = Struct.new(
      :chain, :class_name, :module_path, :methods, :children, :paginated,
      keyword_init: true
    )

    def initialize(spec, map, registry)
      @spec = spec
      @map = map
      @registry = registry
      @resources = {}
    end

    def build
      @map.each { |route, target| add(route, target) }
      @resources.each_value { |r| r.paginated = paginated?(r) }
      @resources
    end

    private

    def add(route, target)
      *chain, method_name = target.split(".")
      resource = resource_for(chain)
      resource.methods << build_method(route, chain, method_name)
    end

    def resource_for(chain)
      @resources[chain] ||= begin
        # Register with the parent so `client.applications.company` resolves.
        parent = resource_for(chain[0..-2]) if chain.size > 1
        definition = ResourceDef.new(
          chain: chain,
          # Suffixed so class names stay singular-safe: a bare +Cards+ is a
          # plural noun that misleads and trips the Rails inflector. Every node
          # in the tree gets it, so the convention is uniform at any depth
          # (+companies.signatures+ -> +SignaturesResource+, not +Signatures+).
          class_name: "#{Naming.pascal(chain.last)}Resource",
          module_path: chain.map { |segment| Naming.pascal(segment) },
          methods: [],
          children: [],
          paginated: false
        )
        parent&.children&.push(definition)
        definition
      end
    end

    def build_method(route, chain, method_name)
      operation = @spec.routes.fetch(route)
      path = operation["path"]

      path_params = (operation["parameters"] || []).map { |p| @spec.deref(p) }.select { |p| p["in"] == "path" }
      query_params = (operation["parameters"] || []).map { |p| @spec.deref(p) }.select { |p| p["in"] == "query" }

      # Stainless makes the deepest path param positional and any ancestors
      # required keywords (`ubo.update(ubo_id, company_id:)`). Mirrored so our
      # call sites read the same as the Python SDK's.
      positional = path_params.last
      ancestors  = path_params[0..-2] || []

      body_schema, multipart = request_body(operation)
      returns, binary = response_type(operation, chain, method_name)

      Method.new(
        name: method_name,
        verb: operation["verb"],
        path: path,
        summary: operation["summary"],
        description: operation["description"],
        positional: positional && Naming.safe_param(positional["name"]),
        params: ancestors.map { |p| param(p, :path) } +
                query_params.map { |p| param(p, :query) } +
                body_params(body_schema, multipart),
        returns: returns,
        binary: binary,
        multipart: multipart
      )
    end

    def param(spec_param, kind)
      schema = @spec.deref(spec_param["schema"] || {})
      Param.new(
        ruby_name: Naming.safe_param(spec_param["name"]),
        api_name: spec_param["name"],
        description: spec_param["description"],
        required: kind == :path || spec_param["required"] == true,
        enum: schema["enum"] || enum_of(spec_param["schema"]),
        kind: kind,
        yard_type: yard_type_for(spec_param["schema"])
      )
    end

    # Params are what a caller passes in, so they're described in terms of what
    # this gem accepts (a Hash for a nested object, Redrain::Upload for a file)
    # rather than the model classes responses come back as.
    def yard_type_for(schema, kind = nil)
      return "Redrain::Upload, File, String" if kind == :file

      schema = @spec.deref(schema || {})
      schema, = @spec.flatten(schema) if schema["allOf"]
      case schema["type"]
      when "array"   then "Array<#{yard_type_for(schema["items"])}>"
      when "integer" then "Integer"
      when "number"  then "Float"
      when "boolean" then "Boolean"
      when "object"  then "Hash"
      when "string"  then schema["format"] == "date-time" ? "Time, String" : "String"
      else "Object"
      end
    end

    def request_body(operation)
      content = operation.dig("requestBody", "content") or return [nil, false]

      if (multipart = content["multipart/form-data"])
        [@spec.flatten(@spec.deref(multipart["schema"])).first, true]
      else
        [@spec.flatten(@spec.deref(content.dig("application/json", "schema"))).first, false]
      end
    end

    def body_params(schema, multipart)
      return [] unless schema

      required = schema["required"] || []
      (schema["properties"] || {}).map do |name, property|
        property = @spec.deref(property)
        kind = multipart && property["format"] == "binary" ? :file : :body
        Param.new(
          ruby_name: Naming.safe_param(name),
          api_name: name,
          description: property["description"],
          required: required.include?(name),
          enum: property["enum"] || enum_of(property),
          kind: kind,
          yard_type: yard_type_for(property, kind)
        )
      end
    end

    def enum_of(schema)
      ref = @spec.ref_name(schema)
      return nil unless ref

      target = @registry.component(ref)
      target.is_a?(Registry::EnumDef) ? target.values : nil
    end

    # Returns [ruby_type_expression_or_nil, binary?].
    def response_type(operation, chain, method_name)
      code, response = (operation["responses"] || {}).find { |status, _| status.start_with?("2") }
      return [nil, false] if response.nil? || code == "204" || response["content"].nil?
      return [nil, true] if response["content"]["application/octet-stream"]

      schema = response.dig("content", "application/json", "schema")
      return [nil, false] if schema.nil?

      [json_response_type(schema, chain, method_name), false]
    end

    def json_response_type(schema, chain, method_name)
      # A named component, or an array of one, needs no class of its own.
      if (ref = @spec.ref_name(schema))
        return ref
      end

      if schema["type"] == "array"
        return "[#{json_response_type(schema["items"], chain, method_name)}]"
      end

      name = Naming.response_class(chain.last, method_name)
      @registry.define(name, schema)
      name
    end

    # A `list` taking both cursor and limit is a cursor-paginated collection, so
    # the resource gets Redrain::Page mixed in.
    def paginated?(resource)
      list = resource.methods.find { |m| m.name == "list" }
      return false unless list

      names = list.params.map(&:ruby_name)
      names.include?("cursor") && names.include?("limit")
    end
  end
end
