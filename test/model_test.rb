# frozen_string_literal: true

require_relative "test_helper"

class ModelTest < Minitest::Test
  class Address < Redrain::Model
    field :postal_code, :string, api: "postalCode"
    field :country, :string
  end

  class Person < Redrain::Model
    field :first_name, :string, api: "firstName"
    field :age, :integer
    field :height, :number
    field :active, :boolean, api: "isActive"
    field :created_at, :time, api: "createdAt"
    field :metadata, :object
    field :address, Address
    field :previous_addresses, [Address], api: "previousAddresses"
  end

  def build(overrides = {})
    Person.from_api({ "firstName" => "Ada", "age" => 36 }.merge(overrides))
  end

  def test_reads_camel_case_keys_through_snake_case_readers
    assert_equal "Ada", build.first_name
  end

  def test_from_api_returns_nil_for_nil
    assert_nil Person.from_api(nil)
  end

  def test_coerces_scalars
    person = build("age" => "36", "height" => "1.7", "isActive" => "true")

    assert_equal 36, person.age
    assert_in_delta 1.7, person.height
    assert_equal true, person.active
  end

  def test_parses_iso8601_timestamps
    person = build("createdAt" => "2026-07-20T11:14:16.729Z")

    assert_equal Time.utc(2026, 7, 20, 11, 14, 16), person.created_at.floor
    assert_in_delta 0.729, person.created_at.subsec.to_f
  end

  def test_falls_back_to_epoch_millis_when_the_timestamp_is_numeric
    person = build("createdAt" => 1_784_546_056_000)

    assert_equal 2026, person.created_at.utc.year
  end

  def test_leaves_an_unparseable_timestamp_alone_rather_than_raising
    person = build("createdAt" => "whenever")

    assert_equal "whenever", person.created_at
  end

  def test_builds_nested_models
    person = build("address" => { "postalCode" => "1012 AB", "country" => "NL" })

    assert_instance_of Address, person.address
    assert_equal "1012 AB", person.address.postal_code
  end

  def test_builds_arrays_of_nested_models
    person = build("previousAddresses" => [{ "country" => "NL" }, { "country" => "DE" }])

    assert_equal %w[NL DE], person.previous_addresses.map(&:country)
  end

  def test_returns_nil_for_absent_fields
    assert_nil build.address
    assert_nil build.previous_addresses
  end

  def test_leaves_free_form_objects_as_hashes
    person = build("metadata" => { "anything" => [1, 2] })

    assert_equal({ "anything" => [1, 2] }, person.metadata)
  end

  # The API adding a field must never break a running integration.
  def test_preserves_unknown_keys
    person = build("loyaltyTier" => "gold")

    assert_equal "gold", person["loyaltyTier"]
    assert_equal "gold", person.to_h["loyaltyTier"]
    assert_equal "gold", person.to_snake_h["loyaltyTier"]
  end

  def test_key_distinguishes_absent_from_null
    person = build("address" => nil)

    assert person.key?(:address)
    refute person.key?(:metadata)
  end

  def test_to_h_round_trips_the_wire_format
    payload = { "firstName" => "Ada", "age" => 36, "address" => { "country" => "NL" } }

    assert_equal payload, Person.from_api(payload).to_h
  end

  def test_to_snake_h_uses_ruby_names_and_coerced_values
    snake = build("isActive" => "true").to_snake_h

    assert_equal "Ada", snake[:first_name]
    assert_equal true, snake[:active]
  end

  def test_equality_is_by_payload
    assert_equal build, build
    refute_equal build, build("age" => 1)
  end

  def test_inspect_shows_only_the_keys_that_were_sent
    assert_equal %(#<ModelTest::Person first_name="Ada" age=36>), build.inspect
  end

  # Inheritance is how the generator models allOf, so fields must accumulate.
  def test_subclasses_inherit_fields_without_mutating_the_parent
    child = Class.new(Person) { field :nickname, :string }

    assert_equal "Zaza", child.from_api("nickname" => "Zaza").nickname
    refute_includes Person.fields.keys, :nickname
  end

  def test_generated_models_expose_declared_fields
    user = Redrain::IssuingUser.from_api("firstName" => "Ada", "isActive" => true)

    assert_equal "Ada", user.first_name
    assert_equal true, user.is_active
  end

  # IssuingTransaction merges four oneOf variants behind a discriminator.
  def test_discriminated_unions_expose_variant_predicates
    transaction = Redrain::IssuingTransaction.from_api("type" => "spend", "spend" => { "amount" => 500 })

    assert transaction.spend?
    refute transaction.fee?
    assert_equal 500, transaction.spend.amount
    assert_nil transaction.fee
  end

  def test_to_h_hands_out_a_copy_the_caller_cannot_corrupt_the_model_with
    person = build
    copy = person.to_h
    copy["firstName"] = "Grace"

    assert_equal "Ada", person.first_name
  end

  def test_equality_does_not_leak_across_a_subclass_boundary
    child = Class.new(Person)
    payload = { "firstName" => "Ada" }

    refute_equal Person.from_api(payload), child.from_api(payload)
    refute_equal child.from_api(payload), Person.from_api(payload)
  end

  # Silently emptying the model would leave no trace that Rain sent something
  # other than the object the spec promised.
  def test_keeps_a_payload_that_was_not_an_object
    person = Person.from_api("just a string")

    assert_equal "just a string", person.raw[Redrain::Model::UNEXPECTED_KEY]
    assert_nil person.first_name
  end

  def test_reads_by_ruby_name_as_well_as_wire_name
    person = build

    assert_equal "Ada", person[:first_name]
    assert_equal "Ada", person["firstName"]
  end
end
