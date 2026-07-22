# frozen_string_literal: true

module Redrain
  # Base for everything this gem raises. Rescue this to catch it all.
  class Error < StandardError; end

  # Raised for local misconfiguration — missing API key, unknown environment.
  class ConfigurationError < Error; end

  # Base for anything that went wrong talking to Rain.
  class APIError < Error; end

  # The request never got an answer: DNS, TLS, refused connection, reset socket.
  class APIConnectionError < APIError; end

  # A connection error where the failure was specifically a timeout.
  class APITimeoutError < APIConnectionError; end

  # Rain answered, but with a non-2xx status.
  class APIStatusError < APIError
    # @return [Integer] the HTTP status Rain replied with
    attr_reader :status

    # @return [Hash, String, nil] parsed error body, or the raw text when it
    #   wasn't JSON. Rain documents no schema for these — treat it as opaque.
    attr_reader :body

    # @return [Hash{String => String}] response headers, keys downcased
    attr_reader :headers

    # @param message [String] exception message
    # @param status [Integer] HTTP status
    # @param body [Hash, String, nil] parsed error body
    # @param headers [Hash{String => String}] response headers, keys downcased
    def initialize(message, status:, body: nil, headers: {})
      super(message)
      @status  = status
      @body    = body
      @headers = headers
    end

    # Rain's error bodies have no documented schema, so this is best-effort.
    # @return [String, nil] the message or error field, if there was one
    def error_message = @body.is_a?(Hash) ? (@body["message"] || @body["error"]) : nil

    # @return [String, nil] quote this when contacting Rain support
    def request_id = @headers["x-request-id"]

    # Maps an HTTP status to the most specific error class we have.
    # @param status [Integer]
    # @return [Class<Redrain::APIStatusError>]
    def self.for(status)
      case status
      when 400 then BadRequestError
      when 401 then AuthenticationError
      when 403 then PermissionDeniedError
      when 404 then NotFoundError
      when 409 then ConflictError
      when 422 then UnprocessableEntityError
      when 429 then RateLimitError
      when 500.. then InternalServerError
      else APIStatusError
      end
    end
  end

  # 400 — Rain rejected the request as malformed.
  class BadRequestError < APIStatusError; end

  # 401 — the API key is missing, wrong, or revoked.
  class AuthenticationError < APIStatusError; end

  # 403 — authenticated, but not allowed to do this.
  class PermissionDeniedError < APIStatusError; end

  # 404 — no such resource.
  class NotFoundError < APIStatusError; end

  # 409 — conflicting state. Retried automatically before it reaches you.
  class ConflictError < APIStatusError; end

  # 422 — well-formed, but Rain wouldn't accept the values.
  class UnprocessableEntityError < APIStatusError; end

  # 429 — rate limited. Retried automatically, honouring Retry-After, before it
  # reaches you.
  class RateLimitError < APIStatusError; end

  # 5xx — Rain failed. Retried automatically before it reaches you.
  class InternalServerError < APIStatusError; end
end
