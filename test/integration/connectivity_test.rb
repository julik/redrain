# frozen_string_literal: true

require_relative "integration_helper"

# Read-only smoke tests: enough to prove auth, base URL, JSON parsing and
# pagination work against the live dev API without creating anything.
class ConnectivityTest < Minitest::Test
  include IntegrationHelper

  def test_authenticates_and_reads_balances
    balances = client.balances.retrieve

    assert_kind_of Redrain::BalanceRetrieveResponse, balances
    assert_kind_of Integer, balances.credit_limit
  end

  def test_a_bad_key_is_reported_as_an_authentication_error
    bad = Redrain::Client.new(api_key: "definitely-not-a-key", environment: :dev)

    assert_raises(Redrain::AuthenticationError) { bad.balances.retrieve }
  end

  def test_lists_users
    users = client.users.list(limit: 5)

    assert_kind_of Array, users
    users.each { |user| assert_kind_of Redrain::IssuingUser, user }
  end

  def test_lists_cards
    cards = client.cards.list(limit: 5)

    assert_kind_of Array, cards
    cards.each { |card| assert_kind_of Redrain::IssuingCard, card }
  end

  def test_lists_contracts
    assert_kind_of Array, client.contracts.list
  end

  def test_pages_through_transactions_without_repeating_itself
    seen = []
    client.transactions.auto_paging_each(limit: 2) do |transaction|
      seen << transaction.id
      break if seen.size >= 5
    end

    assert_equal seen.uniq, seen
  end

  def test_an_unknown_id_is_reported_as_not_found
    assert_raises(Redrain::NotFoundError) do
      client.users.retrieve("00000000-0000-4000-8000-000000000000")
    end
  end
end
