# frozen_string_literal: true

require_relative "writer"

module Generator
  # Emits one WebMock smoke test per top-level resource: every endpoint is
  # called once and asserted on method, URL, auth header, and return type.
  # These prove the wiring; behaviour lives in the hand-written tests.
  class TestWriter
    include Writer

    # Stand-in values per JSON shape, so a generated call has something to send.
    SAMPLE_ID = "00000000-0000-4000-8000-000000000000"

    def initialize(root, resources)
      @root = root
      @resources = resources
      @dir = File.join(root, "test", "resources")
    end

    def write
      roots = @resources.each_value.select { |d| d.chain.size == 1 }.sort_by(&:chain)
      written = roots.map do |definition|
        path = File.join(@dir, "#{Naming.snake(definition.chain.first)}_test.rb")
        write_file(path, source(definition))
        path
      end
      prune(@dir, written.map { |p| File.expand_path(p) })
    end

    private

    def source(definition)
      cases = descendants(definition).flat_map { |resource| resource.methods.map { |m| test_case(resource, m) } }
      <<~RUBY.rstrip
        #{BANNER}
        require_relative "../test_helper"

        class #{Naming.pascal(definition.chain.first)}ResourceTest < Minitest::Test
          include ResourceTestHelper

        #{cases.join("\n\n")}
        end
      RUBY
    end

    def descendants(definition)
      [definition] + definition.children.flat_map { |child| descendants(child) }
    end

    def test_case(resource, method)
      accessor = resource.chain.map { |segment| Naming.snake(segment) }.join(".")
      name = "test_#{resource.chain.join("_")}_#{method.name}"
      url  = method.path.gsub(/\{\w+\}/) { SAMPLE_ID }

      <<~RUBY.rstrip.gsub(/^/, "  ")
        def #{name}
          stub = stub_api(:#{method.verb.downcase}, "#{url}"#{stub_options(method)})

          result = client.#{accessor}.#{method.name}#{arguments(method)}

          assert_requested(stub)
          #{assertion(method)}
        end
      RUBY
    end

    def stub_options(method)
      options = []
      options << expected_query(method)
      options << expected_body(method)
      if method.binary
        options << %(body: BINARY_FIXTURE, content_type: "application/octet-stream")
      elsif method.returns.nil?
        options << "status: 204"
      else
        options << "body: #{response_fixture(method.returns)}"
      end
      options.compact.map { |o| ", #{o}" }.join
    end

    # Only the required params get sent, so these double as an assertion that
    # optional params left nil are omitted rather than serialised as null.
    def expected_query(method)
      params = method.params.select { |p| p.kind == :query && p.required }
      return nil if params.empty?

      "query: #{wire_hash(params)}"
    end

    def expected_body(method)
      params = method.params.select { |p| p.kind == :body && p.required }
      # Multipart bodies aren't a JSON hash, so leave them to the hand-written
      # upload tests rather than asserting a boundary-delimited string here.
      return nil if params.empty? || method.multipart

      "sends: #{wire_hash(params)}"
    end

    def wire_hash(params)
      pairs = params.map { |p| %("#{p.api_name}" => #{sample_value(p)}) }
      "{ #{pairs.join(", ")} }"
    end

    # The generated stubs return empty shapes: enough for the parser to build a
    # model, not enough to assert anything about field content.
    def response_fixture(type)
      type.start_with?("[") ? "[]" : "{}"
    end

    def arguments(method)
      parts = []
      parts << SAMPLE_ID.inspect if method.positional
      method.params.select(&:required).each do |param|
        parts << "#{param.ruby_name}: #{sample_value(param)}"
      end
      parts.empty? ? "" : "(#{parts.join(", ")})"
    end

    def sample_value(param)
      return "upload_fixture" if param.kind == :file
      return param.enum.first.inspect if param.enum

      SAMPLE_ID.inspect
    end

    def assertion(method)
      return "assert_equal BINARY_FIXTURE, result" if method.binary
      return "assert_nil result" if method.returns.nil?
      return "assert_equal [], result" if method.returns.start_with?("[")

      "assert_kind_of Redrain::#{method.returns}, result"
    end
  end
end
