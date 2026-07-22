# frozen_string_literal: true

module Redrain
  # Base for every generated resource. Holds the client and turns declarative
  # calls from the generated methods into HTTP requests.
  class Resource
    # @param client [Redrain::Client]
    def initialize(client)
      @client = client
      # Built up front so concurrent first calls race only on the entries, never
      # on the container itself.
      @sub_resources = {}
    end

    # @return [Redrain::Client] the client this resource issues requests through
    attr_reader :client

    # Declares a memoised sub-resource accessor: +sub_resource :pin, Pin+ gives
    # you +client.cards.pin+, built once per parent.
    #
    # @param name [Symbol] accessor name
    # @param klass [Class<Redrain::Resource>]
    # @return [void]
    def self.sub_resource(name, klass)
      define_method(name) { @sub_resources[name] ||= klass.new(@client) }
    end

    private

    # @param method [Symbol] HTTP verb
    # @param path [String] path below the base URL
    # @param query [Hash, nil] query params
    # @param body [Hash, nil] request body; nil values are stripped
    # @param files [Hash, nil] multipart file parts
    # @param binary [Boolean] return the raw body rather than parsing it
    # @param into [Class<Redrain::Model>, Array, nil] what to coerce the
    #   response into; nil for endpoints with no body
    # @return [Redrain::Model, Array, String, nil]
    def request(method, path, query: nil, body: nil, files: nil, binary: false, into: nil)
      response = @client.http.request(
        method, path,
        query: query,
        body: body && compact(body),
        files: files,
        binary: binary
      )
      return response if binary || into.nil?

      Model.cast(response, into)
    end

    # Interpolates path params and escapes them — an id with a slash in it must
    # not be able to reach a different endpoint.
    # @param template [String] path with +{camelCase}+ placeholders
    # @param params [Hash{Symbol => Object}] placeholder values
    # @return [String] the interpolated, escaped path
    # @raise [ArgumentError] on a missing, empty or dot-only value
    def path(template, **params)
      template.gsub(/\{(\w+)\}/) do
        key = Regexp.last_match(1).to_sym
        raise ArgumentError, "missing path parameter `#{key}`" unless params.key?(key)

        escape_segment(key, params[key])
      end
    end

    # Percent-encodes everything outside RFC 3986's unreserved set, so an id can
    # never break out of its path segment. "." and ".." are rejected outright
    # rather than escaped: they survive encoding intact, and a normalising proxy
    # in front of Rain would resolve them into a different endpoint.
    def escape_segment(key, value)
      value = value.to_s
      raise ArgumentError, "expected a non-empty value for `#{key}`, got #{value.inspect}" if value.empty?
      raise ArgumentError, "path parameter `#{key}` may not be #{value.inspect}" if value.match?(/\A\.+\z/)

      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~]/)
    end

    # nil means "not given" — omitted rather than sent as JSON null, matching
    # the Python SDK's Omit sentinel.
    def compact(hash) = hash.compact
  end
end
