# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def clean_env(&block) = with_env({ "RAIN_API_KEY" => nil, "RAIN_BASE_URL" => nil }, &block)

  def test_the_default_environment_is_visible_in_the_signature
    parameters = Redrain::Client.instance_method(:initialize).parameters

    assert_includes parameters, [:key, :environment], "environment must be optional, not required"
    assert_equal :dev, Redrain::Client::DEFAULT_ENVIRONMENT
  end

  def test_defaults_to_the_dev_environment
    clean_env do
      client = Redrain::Client.new(api_key: "k")

      assert_equal :dev, client.environment
      assert_equal "https://api-dev.raincards.xyz/v1/issuing", client.base_url
    end
  end

  def test_resolves_the_production_environment
    clean_env do
      assert_equal "https://api.raincards.xyz/v1/issuing",
        Redrain::Client.new(api_key: "k", environment: :production).base_url
    end
  end

  def test_accepts_the_environment_as_a_string
    clean_env do
      assert_equal :production, Redrain::Client.new(api_key: "k", environment: "production").environment
    end
  end

  def test_rejects_an_unknown_environment
    clean_env do
      error = assert_raises(Redrain::ConfigurationError) { Redrain::Client.new(api_key: "k", environment: :staging) }

      assert_includes error.message, "Unknown environment"
    end
  end

  def test_reads_the_api_key_from_the_environment
    with_env("RAIN_API_KEY" => "from-env", "RAIN_BASE_URL" => nil) do
      assert_kind_of Redrain::Client, Redrain::Client.new
    end
  end

  def test_requires_an_api_key
    clean_env do
      error = assert_raises(Redrain::ConfigurationError) { Redrain::Client.new }

      assert_includes error.message, "RAIN_API_KEY"
    end
  end

  def test_treats_an_empty_api_key_as_missing
    clean_env do
      assert_raises(Redrain::ConfigurationError) { Redrain::Client.new(api_key: "") }
    end
  end

  def test_reads_the_base_url_from_the_environment
    with_env("RAIN_BASE_URL" => "https://rain.test/v1") do
      client = Redrain::Client.new(api_key: "k")

      assert_equal "https://rain.test/v1", client.base_url
      assert_nil client.environment
    end
  end

  # base_url: > RAIN_BASE_URL > environment:.
  def test_rain_base_url_overrides_the_environment
    with_env("RAIN_BASE_URL" => "https://rain.test/v1") do
      client = Redrain::Client.new(api_key: "k", environment: :production)

      assert_equal "https://rain.test/v1", client.base_url
      assert_nil client.environment
    end
  end

  # An override must not let a typo through — it would surface much later, as a
  # confusing failure the day the override is removed.
  def test_validates_the_environment_even_when_a_base_url_overrides_it
    with_env("RAIN_BASE_URL" => "https://rain.test/v1") do
      assert_raises(Redrain::ConfigurationError) { Redrain::Client.new(api_key: "k", environment: :staging) }
    end
    clean_env do
      assert_raises(Redrain::ConfigurationError) do
        Redrain::Client.new(api_key: "k", environment: :staging, base_url: "https://x.test")
      end
    end
  end

  def test_an_explicit_base_url_wins_over_everything
    with_env("RAIN_BASE_URL" => "https://rain.test/v1") do
      client = Redrain::Client.new(api_key: "k", environment: :dev, base_url: "https://explicit.test")

      assert_equal "https://explicit.test", client.base_url
    end
  end

  def test_exposes_every_top_level_resource
    client = Redrain::Client.new(api_key: "k")

    %i[applications balances cards companies contracts disputes keys payments signatures
       transactions users].each do |name|
      assert_respond_to client, name
      assert_kind_of Redrain::Resource, client.public_send(name)
    end
  end

  def test_resources_are_memoised
    client = Redrain::Client.new(api_key: "k")

    assert_same client.users, client.users
    assert_same client.cards.pin, client.cards.pin
  end

  def test_inspect_does_not_leak_the_api_key
    refute_includes Redrain::Client.new(api_key: "sk-secret").inspect, "sk-secret"
  end

  def test_forwards_default_headers
    stub = stub_request(:get, "#{TEST_BASE_URL}/balances")
      .with(headers: { "X-Tenant" => "zay" }).to_return(status: 200, body: "{}")

    Redrain::Client.new(api_key: "k", environment: :dev, default_headers: { "X-Tenant" => "zay" })
                   .balances.retrieve

    assert_requested(stub)
  end

  def test_rejects_a_base_url_with_no_scheme
    with_env("RAIN_BASE_URL" => "api.raincards.xyz/v1") do
      error = assert_raises(Redrain::ConfigurationError) { Redrain::Client.new(api_key: "k") }

      assert_includes error.message, "http(s) URL"
    end
  end
end
