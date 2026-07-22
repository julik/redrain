# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# Guards the port's contract with the upstream SDK: every route Rain publishes
# reaches a real Ruby method, and the generated tree still matches the spec.
class CoverageTest < Minitest::Test
  ROOT  = File.expand_path("..", __dir__)
  MAP   = YAML.load_file(File.join(ROOT, "dev", "resource_map.yml"))
  SPEC  = JSON.parse(File.read(File.join(ROOT, "openapi", "rain-issuing.json")))
  STATS = YAML.load_file(File.join(ROOT, "openapi", "stats.yml"))

  def client = @client ||= Redrain::Client.new(api_key: TEST_API_KEY, environment: :dev)

  def test_every_mapped_route_resolves_to_a_method
    missing = MAP.filter_map do |route, target|
      *chain, method_name = target.split(".")
      resource = chain.reduce(client) { |object, segment| object.public_send(segment) }
      "#{route} -> #{target}" unless resource.respond_to?(method_name)
    rescue NoMethodError
      "#{route} -> #{target}"
    end

    assert_empty missing, "endpoints with no Ruby method"
  end

  def test_the_map_covers_the_whole_spec
    routes = SPEC["paths"].flat_map { |path, methods| methods.keys.map { |verb| "#{verb.upcase} #{path}" } }

    assert_equal routes.sort, MAP.keys.sort
  end

  def test_the_endpoint_count_matches_what_the_python_sdk_configured
    assert_equal STATS["configured_endpoints"], MAP.size
  end

  # A regenerated tree must load without a NameError from a forward reference.
  def test_every_declared_field_type_resolves
    Redrain.constants.map { |name| Redrain.const_get(name) }
           .select { |constant| constant.is_a?(Class) && constant < Redrain::Model }
           .each do |model|
      model.fields.each_value do |field|
        type = field[:type]
        type = type.first if type.is_a?(Array)
        next if type.is_a?(Symbol)

        assert_operator type, :<, Redrain::Model, "#{model}##{field[:name]}"
      end
    end
  end
end
