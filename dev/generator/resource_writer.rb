# frozen_string_literal: true

require_relative "writer"

module Generator
  # Emits one file per top-level resource, each holding its whole sub-tree, plus
  # lib/redrain/resources.rb which requires them and reopens Client to hang the
  # top-level accessors off it.
  #
  # Sub-resources nest as classes inside their parent's class body rather than
  # in parallel modules — `Ubo` can't be both the class backing
  # `client.applications.company.ubo` and the namespace holding `Document`.
  class ResourceWriter
    include Writer

    def initialize(root, resources)
      @root = root
      @resources = resources
      @dir = File.join(root, "lib", "redrain", "resources")
    end

    def write
      written = roots.map { |definition| emit(definition) }
      prune(@dir, written.map { |p| File.expand_path(p) })
      write_manifest
    end

    private

    def roots = @resources.each_value.select { |d| d.chain.size == 1 }.sort_by(&:chain)

    def file_name(definition) = "#{Naming.snake(definition.chain.first)}.rb"

    def emit(definition)
      path = File.join(@dir, file_name(definition))
      write_file(path, source(definition))
      path
    end

    def source(definition)
      <<~RUBY.rstrip
        #{BANNER}
        module Redrain
          # One class per node of Rain's resource tree, reachable from
          # {Redrain::Client}. Generated — see dev/generate.rb.
          module Resources
        #{class_source(definition, "    ")}
          end
        end
      RUBY
    end

    def class_source(definition, indent)
      inner = indent + "  "
      lines = class_doc(definition, indent)
      lines << "#{indent}class #{definition.class_name} < Resource"

      definition.children.each do |child|
        lines << class_source(child, inner)
        lines << ""
      end

      lines << "#{inner}include Redrain::Page" if definition.paginated
      definition.children.each do |child|
        lines << "#{inner}sub_resource :#{Naming.snake(child.chain.last)}, #{child.class_name}"
      end
      lines << "" if definition.paginated || definition.children.any?

      definition.methods.each_with_index do |method, index|
        lines << "" if index.positive?
        lines.concat(method_lines(method, inner))
      end
      lines << "#{indent}end"
      lines.join("\n")
    end

    # Resource classes have no spec description of their own, so name the call
    # path they back and the routes they cover.
    def class_doc(definition, indent)
      accessor = definition.chain.map { |segment| Naming.snake(segment) }.join(".")
      routes = definition.methods.map { |m| "#{m.verb} #{m.path.gsub(/\{(\w+)\}/) { ":#{Regexp.last_match(1)}" }}" }

      lines = comment("Backs +client.#{accessor}+.", indent: indent)
      lines << "#{indent}#"
      lines.concat(comment("Covers #{routes.size == 1 ? "" : "#{routes.size} endpoints: "}#{routes.join(", ")}.", indent: indent))
      lines
    end

    def method_lines(method, indent)
      lines = []
      lines.concat(comment(method.summary, indent: indent))
      lines << "#{indent}#" if method.summary && method.description
      lines.concat(comment(method.description, indent: indent))
      lines << "#{indent}#"
      # Colon-style placeholders rather than the spec's {braces}: YARD reads
      # {anything} in a docstring as a link and warns it can't resolve it.
      route = method.path.gsub(/\{(\w+)\}/) { ":#{Regexp.last_match(1)}" }
      lines << "#{indent}# #{method.verb} #{route}"
      lines.concat(param_docs(method, indent))
      lines.concat(return_doc(method, indent))

      lines.concat(definition_lines(method, indent))
      lines.concat(body_lines(method, indent + "  "))
      lines << "#{indent}end"
      lines
    end

    def param_docs(method, indent)
      lines = ["#{indent}#"]
      lines.concat(tag("@param [String] #{method.positional}", "the resource id", indent)) if method.positional

      method.params.each do |param|
        text = [
          param.description&.sub(/\.\z/, ""),
          param.enum && "one of: #{param.enum.join(", ")}",
          param.required ? nil : "optional"
        ].compact.join(". ")
        lines.concat(tag("@param [#{param.yard_type}] #{param.ruby_name}", text, indent))
      end
      lines.size == 1 ? [] : lines
    end

    def return_doc(method, indent)
      type = if method.binary
        "String"
      elsif method.returns.nil?
        "nil"
      else
        Naming.yard_type(method.returns)
      end
      description = if method.binary
        "the raw bytes of the response"
      elsif method.returns.nil?
        "this endpoint returns no content"
      else
        ""
      end
      tag("@return [#{type}]", description, indent)
    end

    # Wraps a tag's prose, indenting continuation lines the way YARD expects.
    def tag(head, text, indent)
      wrapped = comment([head, text].reject { |part| part.nil? || part.empty? }.join(" "), indent: indent)
      [wrapped.first, *wrapped[1..].map { |line| line.sub("# ", "#   ") }]
    end

    def definition_lines(method, indent)
      parts = signature_parts(method)
      return ["#{indent}def #{method.name}"] if parts.empty?

      single = "#{indent}def #{method.name}(#{parts.join(", ")})"
      return [single] if single.length <= WIDTH

      # Long parameter lists get one per line — these run to a dozen keywords on
      # the application endpoints and are unreadable on a single line.
      ["#{indent}def #{method.name}(", *parts.map { |p| "#{indent}  #{p}," }, "#{indent})"].tap do |lines|
        lines[-2] = lines[-2].chomp(",")
      end
    end

    def signature_parts(method)
      parts = []
      parts << method.positional if method.positional
      required, optional = method.params.partition(&:required)
      # nil is the "not given" sentinel everywhere, so every optional param
      # defaults to it and gets stripped before the request goes out.
      parts.concat(required.map { |p| "#{p.ruby_name}:" })
      parts.concat(optional.map { |p| "#{p.ruby_name}: nil" })
      parts
    end

    def body_lines(method, indent)
      query = method.params.select { |p| p.kind == :query }
      body  = method.params.select { |p| p.kind == :body }
      files = method.params.select { |p| p.kind == :file }

      lines = []
      lines.concat(hash_literal("query", query, indent))
      lines.concat(hash_literal("body", body, indent))
      lines.concat(hash_literal("files", files, indent))
      lines << "" unless lines.empty?

      call = +"request(:#{method.verb.downcase}, #{path_expression(method)}"
      call << ", query: query" if query.any?
      call << ", body: body"   if body.any?
      call << ", files: files" if files.any?
      call << ", binary: true" if method.binary
      call << ", into: #{method.returns}" if method.returns
      call << ")"
      lines.concat(wrap_call(call, indent))
    end

    # Rain's paths carry camelCase placeholders ({companyId}); the resource base
    # escapes whatever we substitute in.
    def path_expression(method)
      placeholders = method.path.scan(/\{(\w+)\}/).flatten
      return method.path.inspect if placeholders.empty?

      args = placeholders.map { |name| "#{name}: #{Naming.safe_param(name)}" }
      %(path("#{method.path}", #{args.join(", ")}))
    end

    def hash_literal(name, params, indent)
      return [] if params.empty?

      lines = ["#{indent}#{name} = {"]
      params.each { |p| lines << %(#{indent}  "#{p.api_name}" => #{p.ruby_name},) }
      lines[-1] = lines[-1].chomp(",")
      lines << "#{indent}}"
      lines
    end

    def wrap_call(call, indent)
      single = "#{indent}#{call}"
      return [single] if single.length <= WIDTH

      head, rest = call.split("(", 2)
      arguments = split_arguments(rest.chomp(")"))
      lines = ["#{indent}#{head}(", *arguments.map { |a| "#{indent}  #{a}," }, "#{indent})"]
      lines[-2] = lines[-2].chomp(",")
      lines
    end

    # Splits on commas at nesting depth zero, so `path("/x/{id}", id: id)` stays
    # in one piece.
    def split_arguments(text)
      depth = 0
      current = +""
      arguments = []
      text.each_char do |char|
        case char
        when "(", "[", "{" then depth += 1
        when ")", "]", "}" then depth -= 1
        end
        if char == "," && depth.zero?
          arguments << current.strip
          current = +""
        else
          current << char
        end
      end
      arguments << current.strip
      arguments.reject(&:empty?)
    end

    def write_manifest
      requires = roots.map { |d| %(require_relative "resources/#{file_name(d).chomp(".rb")}") }
      accessors = roots.map do |definition|
        name = Naming.snake(definition.chain.first)
        [
          "    # @return [Resources::#{definition.class_name}] the #{name} resource, memoised",
          "    def #{name} = @resources[:#{name}] ||= Resources::#{definition.class_name}.new(self)"
        ].join("\n")
      end

      contents = [
        BANNER,
        requires.join("\n"),
        "",
        "module Redrain",
        "  class Client",
        *accessors,
        "  end",
        "end"
      ].join("\n")
      write_file(File.join(@root, "lib", "redrain", "resources.rb"), contents)
    end
  end
end
