# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "time"
require "json"
require "stringio"
require "zlib"
require "securerandom"

module Redrain
  # The one place that talks to the network. Everything above it deals in
  # Ruby objects; everything below it is Net::HTTP.
  class HTTPClient
    # @return [Integer] default read timeout, in seconds
    DEFAULT_TIMEOUT      = 60
    # @return [Integer] default connect timeout, in seconds
    DEFAULT_OPEN_TIMEOUT = 5
    # @return [Integer] default retry budget per request
    DEFAULT_MAX_RETRIES  = 2

    # Matches the Python SDK's 0.5s -> 8s exponential schedule.
    # @return [Float] first backoff, in seconds
    INITIAL_RETRY_DELAY = 0.5
    # @return [Float] backoff ceiling, in seconds
    MAX_RETRY_DELAY     = 8.0

    # Retried because they're transient by definition. 409 is in here to match
    # the Python SDK, which treats it as a lock contention signal.
    # @return [Array<Integer>] non-5xx statuses worth retrying
    RETRIABLE_STATUSES = [408, 409, 429].freeze

    # SystemCallError rather than a hand-picked list of Errno constants: the one
    # you forget is always the one production hits, and every network failure
    # should surface as APIConnectionError so a single rescue covers it.
    # @return [Array<Class>] exceptions treated as "never got an answer"
    CONNECTION_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
      SystemCallError, EOFError, SocketError, IOError, OpenSSL::SSL::SSLError
    ].freeze

    # The subset of {CONNECTION_ERRORS} reported as {Redrain::APITimeoutError}.
    # @return [Array<Class>]
    TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze

    # @param base_url [String] API root; paths are appended to it verbatim
    # @param api_key [String] sent as the +Api-Key+ header
    # @param timeout [Numeric] read timeout in seconds
    # @param open_timeout [Numeric] connect timeout in seconds
    # @param max_retries [Integer] retry budget per request; 0 disables retrying
    # @param default_headers [Hash{String => String}] added to every request
    # @param logger [Logger, nil] debug line per request, warning per retry
    def initialize(base_url:, api_key:, timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES, default_headers: {}, logger: nil)
      @base_url        = base_url.to_s.chomp("/")
      @api_key         = api_key
      @timeout         = timeout
      @open_timeout    = open_timeout
      @max_retries     = max_retries
      @default_headers = default_headers
      @logger          = logger
    end

    # @return [String] the API root every path is appended to
    attr_reader :base_url

    # @return [Integer] retry budget per request
    attr_reader :max_retries

    # Performs one request, retrying transient failures.
    #
    # @param method [Symbol] +:get+, +:post+, +:put+, +:patch+ or +:delete+
    # @param path [String] path below the base URL, e.g. +"/users"+
    # @param query [Hash, nil] query params; nil values are dropped, Arrays are
    #   sent as repeated keys, Times as ISO 8601
    # @param body [Hash, nil] JSON body, or the non-file fields when +files+ is given
    # @param files [Hash{String => Redrain::Upload, IO, String}, nil] file parts;
    #   their presence switches the request to multipart/form-data
    # @param headers [Hash{String => String}] per-request headers; override
    #   anything inferred, including Content-Type
    # @param binary [Boolean] return the body as a String rather than parsing JSON
    # @return [Hash, Array, String, nil] parsed JSON, raw bytes when +binary+,
    #   or nil for a 204
    # @raise [Redrain::APIStatusError] on a non-2xx that survives the retry budget
    # @raise [Redrain::APIConnectionError] when the request never got an answer
    def request(method, path, query: nil, body: nil, files: nil, headers: {}, binary: false)
      uri = build_uri(path, query)
      # Materialise uploads once, before the retry loop. Coercing per attempt
      # would re-read an IO that the first attempt already drained, and the
      # retry would silently send an empty file.
      files = files&.transform_values { |file| file && Upload.coerce(file) }
      attempt = 0

      begin
        @logger&.debug { "redrain #{method.to_s.upcase} #{uri}#{attempt.positive? ? " (retry #{attempt})" : ""}" }
        response = perform(method, uri, body: body, files: files, headers: headers, binary: binary)
        if retriable_status?(response.code.to_i) && attempt < @max_retries
          attempt += 1
          delay = retry_delay(attempt, response["retry-after"])
          @logger&.warn { "redrain #{uri} returned #{response.code}, retrying in #{delay.round(2)}s" }
          sleep(delay)
          raise Retry
        end
        handle(response, binary: binary)
      rescue Retry
        retry
      rescue *CONNECTION_ERRORS => e
        if attempt < @max_retries
          attempt += 1
          delay = retry_delay(attempt, nil)
          @logger&.warn { "redrain #{uri} failed with #{e.class}, retrying in #{delay.round(2)}s" }
          sleep(delay)
          retry
        end
        raise connection_error_for(e)
      end
    end

    private

    # Internal control-flow signal, never escapes #request.
    class Retry < StandardError; end

    def build_uri(path, query)
      uri = URI("#{@base_url}#{path}")
      params = compact_query(query)
      uri.query = URI.encode_www_form(params) unless params.empty?
      uri
    end

    # nil means "not given" throughout the resource layer, so it never hits the wire.
    def compact_query(query)
      return [] unless query

      query.reject { |_, v| v.nil? }.flat_map do |key, value|
        # Rain takes repeated keys for array filters rather than a bracket syntax.
        values = value.is_a?(Array) ? value : [value]
        values.map { |v| [key.to_s, query_value(v)] }
      end
    end

    # Times and dates go out as ISO 8601, mirroring how Model parses them coming
    # back. Ruby's default Time#to_s ("2026-07-22 11:07:20 +0100") is not a
    # format Rain's date filters accept.
    def query_value(value) = value.respond_to?(:iso8601) ? value.iso8601 : value.to_s

    def perform(method, uri, body:, files:, headers:, binary:)
      request = request_class(method).new(uri.request_uri)
      request["Api-Key"]         = @api_key
      request["Accept"]          = binary ? "*/*" : "application/json"
      request["Accept-Encoding"] = "gzip"
      request["User-Agent"]      = "redrain/#{Redrain::VERSION} ruby/#{RUBY_VERSION}"
      @default_headers.each { |k, v| request[k.to_s] = v }

      if files && !files.empty?
        boundary = "----RedrainFormBoundary#{SecureRandom.hex(16)}"
        request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        request.body = multipart_body(body || {}, files, boundary)
      elsif body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      # Applied last so a caller can override anything we inferred, including
      # Content-Type.
      headers.each { |k, v| request[k.to_s] = v }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @timeout
      http.request(request)
    end

    def request_class(method)
      {
        get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put,
        patch: Net::HTTP::Patch, delete: Net::HTTP::Delete
      }.fetch(method) { raise ArgumentError, "unsupported HTTP method #{method.inspect}" }
    end

    # Every append is forced to binary. A UTF-8 field value or filename would
    # otherwise promote the buffer to UTF-8, and appending the file's bytes
    # after that raises Encoding::CompatibilityError.
    def multipart_body(fields, files, boundary)
      out = +"".b
      fields.each do |name, value|
        next if value.nil?

        out << "--#{boundary}\r\n".b
        out << %(Content-Disposition: form-data; name="#{name}"\r\n\r\n).b
        out << "#{value}\r\n".b
      end
      files.each do |name, upload|
        next if upload.nil?

        upload = Upload.coerce(upload)
        out << "--#{boundary}\r\n".b
        out << %(Content-Disposition: form-data; name="#{name}"; filename="#{upload.filename}"\r\n).b
        out << "Content-Type: #{upload.content_type}\r\n\r\n".b
        out << upload.read
        out << "\r\n".b
      end
      out << "--#{boundary}--\r\n".b
      out
    end

    def handle(response, binary:)
      status = response.code.to_i
      raw = decode_body(response)

      return parse_success(status, raw, binary) if (200..299).cover?(status)

      body = parse_json(raw)
      raise APIStatusError.for(status).new(
        error_summary(status, body),
        status: status,
        body: body,
        headers: downcased_headers(response)
      )
    end

    def parse_success(status, raw, binary)
      return nil if status == 204 || raw.nil? || raw.empty?
      return raw if binary

      parse_json(raw)
    end

    def parse_json(raw)
      return nil if raw.nil? || raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      # Rain's error responses have no documented schema — a proxy or gateway
      # can hand back HTML. Keep the text rather than losing the diagnosis.
      raw
    end

    def error_summary(status, body)
      # Rain's error bodies have no schema. Fall back to the serialised body
      # rather than dropping the detail — the message is what lands in the
      # exception tracker, and "returned 422" on its own diagnoses nothing.
      detail = case body
      when Hash then body["message"] || body["error"] || JSON.generate(body)
      else body
      end.to_s[0, 500]

      detail.empty? ? "Rain API returned #{status}" : "Rain API returned #{status}: #{detail}"
    end

    def downcased_headers(response)
      response.each_header.to_h { |k, v| [k.downcase, v] }
    end

    # Net::HTTP only auto-inflates when it sets Accept-Encoding itself. We set
    # it explicitly, which turns that off — so decode here.
    def decode_body(response)
      body = response.body
      return body if body.nil? || body.empty?
      return body unless response["content-encoding"].to_s.downcase.include?("gzip")

      Zlib::GzipReader.new(StringIO.new(body)).read
    rescue Zlib::GzipFile::Error
      body
    end

    def retriable_status?(status) = RETRIABLE_STATUSES.include?(status) || status >= 500

    # Full jitter on the exponential backoff, so a fleet of workers hitting the
    # same 429 doesn't retry in lockstep.
    def retry_delay(attempt, retry_after)
      seconds = parse_retry_after(retry_after)
      # An already-elapsed HTTP-date parses to 0; retrying instantly is worse
      # than not honouring it at all, so clamp to the normal floor.
      return seconds.clamp(INITIAL_RETRY_DELAY, MAX_RETRY_DELAY) if seconds

      capped = [INITIAL_RETRY_DELAY * (2**(attempt - 1)), MAX_RETRY_DELAY].min
      capped * (0.5 + (rand * 0.5))
    end

    def parse_retry_after(value)
      return nil if value.nil? || value.to_s.empty?
      return value.to_f if value.to_s.match?(/\A\d+(\.\d+)?\z/)

      # HTTP-date form.
      [(Time.httpdate(value.to_s) - Time.now), 0].max
    rescue ArgumentError
      nil
    end

    def connection_error_for(error)
      klass = TIMEOUT_ERRORS.any? { |t| error.is_a?(t) } ? APITimeoutError : APIConnectionError
      klass.new("#{error.class}: #{error.message}")
    end
  end
end
