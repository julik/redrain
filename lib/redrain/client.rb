# frozen_string_literal: true

module Redrain
  # Entry point. Holds credentials and hands out resource objects.
  #
  #   rain = Redrain::Client.new(api_key: ENV.fetch("RAIN_API_KEY"), environment: :production)
  #   rain.users.list(limit: 10)
  class Client
    # The two hosts Rain publishes in its OpenAPI document, as "Development
    # server" and "Production server". The +:dev+/+:production+ keys are the
    # Python SDK's shorthand, carried over so call sites match.
    # @return [Hash{Symbol => String}]
    ENVIRONMENTS = {
      dev:        "https://api-dev.raincards.xyz/v1/issuing",
      production: "https://api.raincards.xyz/v1/issuing"
    }.freeze

    # Matches the Python SDK, which also defaults to dev. Reaching production
    # should be a deliberate act.
    DEFAULT_ENVIRONMENT = :dev

    # @return [Redrain::HTTPClient] the transport this client's resources use
    attr_reader :http

    # @return [String] the resolved API root every request is made against
    attr_reader :base_url

    # @return [Symbol, nil] the environment in use, or nil when +base_url+ or
    #   +RAIN_BASE_URL+ overrode it
    attr_reader :environment

    # @param api_key [String, nil] Rain API key. Falls back to the +RAIN_API_KEY+
    #   environment variable.
    # @param environment [Symbol, String] +:dev+ or +:production+. Validated even
    #   when a base URL overrides it, so a typo never passes silently.
    # @param base_url [String, nil] API root to use instead of the environment's.
    #   Takes precedence over everything, including +RAIN_BASE_URL+.
    # @param timeout [Numeric, nil] read timeout in seconds (default 60)
    # @param open_timeout [Numeric, nil] connect timeout in seconds (default 5)
    # @param max_retries [Integer, nil] retry budget per request (default 2, 0 disables)
    # @param default_headers [Hash{String => String}] headers added to every request
    # @param logger [Logger, nil] receives a debug line per request and a warning per retry
    # @raise [Redrain::ConfigurationError] if the API key is missing, the
    #   environment is unknown, or the base URL is not an http(s) URL
    def initialize(api_key: nil, environment: DEFAULT_ENVIRONMENT, base_url: nil, timeout: nil,
                   open_timeout: nil, max_retries: nil, default_headers: {}, logger: nil)
      @api_key = api_key || ENV["RAIN_API_KEY"]
      raise ConfigurationError, <<~MSG.chomp if @api_key.nil? || @api_key.empty?
        No API key. Pass api_key: to Redrain::Client.new or set the RAIN_API_KEY environment variable.
      MSG

      @environment, @base_url = resolve_base_url(environment, base_url)
      validate_base_url!(@base_url)
      # Built up front so concurrent first calls race only on the entries, never
      # on the container itself.
      @resources = {}

      @http = HTTPClient.new(
        base_url: @base_url,
        api_key: @api_key,
        timeout: timeout || HTTPClient::DEFAULT_TIMEOUT,
        open_timeout: open_timeout || HTTPClient::DEFAULT_OPEN_TIMEOUT,
        max_retries: max_retries || HTTPClient::DEFAULT_MAX_RETRIES,
        default_headers: default_headers,
        logger: logger
      )
    end

    # @return [String] never includes the API key
    def inspect = "#<#{self.class.name} environment=#{@environment.inspect} base_url=#{@base_url.inspect}>"

    private

    # A schemeless RAIN_BASE_URL would otherwise fail deep inside Net::HTTP with
    # something unrecognisable, long after the mistake was made.
    def validate_base_url!(base_url)
      return if URI(base_url.to_s).is_a?(URI::HTTP)

      raise ConfigurationError, "Base URL must be an http(s) URL, got #{base_url.inspect}"
    rescue URI::InvalidURIError
      raise ConfigurationError, "Base URL is not a valid URL: #{base_url.inspect}"
    end

    # Precedence, highest first: base_url:, then RAIN_BASE_URL, then environment:.
    #
    # The environment is always validated even when it loses, so a typo can't
    # hide behind an override and surface later when the override goes away.
    def resolve_base_url(environment, base_url)
      environment = environment.to_sym
      url = ENVIRONMENTS[environment]
      unless url
        raise ConfigurationError,
          "Unknown environment #{environment.inspect}, expected one of #{ENVIRONMENTS.keys.inspect}"
      end

      return [nil, base_url] if base_url

      base_url_env = ENV["RAIN_BASE_URL"]
      return [nil, base_url_env] if base_url_env && !base_url_env.empty?

      [environment, url]
    end
  end
end
