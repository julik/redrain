# frozen_string_literal: true

require_relative "integration_helper"

# The two request/response shapes WebMock cannot vouch for: multipart uploads
# and octet-stream downloads. Both need a real endpoint to be worth anything.
#
# They need fixture ids from the dev account — set RAIN_TRANSACTION_ID and
# RAIN_USER_APPLICATION_ID, or these skip.
class BinaryAndUploadTest < Minitest::Test
  include IntegrationHelper

  ONE_PIXEL_PNG = [
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a4944415478" \
    "9c6300010000050001od0a2db40000000049454e44ae426082"
  ].pack("H*")

  def test_uploads_a_document_as_multipart
    application_id = ENV["RAIN_USER_APPLICATION_ID"] or skip "set RAIN_USER_APPLICATION_ID"

    result = client.applications.user.upload_document(
      application_id,
      document: Redrain::Upload.new(ONE_PIXEL_PNG, filename: "id-front.png"),
      type: "idCard",
      side: "front",
      country: "NLD"
    )

    assert_nil result, "a 204 upload should come back as nil"
  end

  def test_downloads_a_receipt_as_bytes
    transaction_id = ENV["RAIN_TRANSACTION_ID"] or skip "set RAIN_TRANSACTION_ID"

    receipt = begin
      client.transactions.receipt.retrieve(transaction_id)
    rescue Redrain::NotFoundError
      skip "transaction #{transaction_id} has no receipt attached"
    end

    assert_kind_of String, receipt
    refute_empty receipt
    # Proves we didn't run it through JSON.parse or mangle the encoding.
    assert_equal Encoding::ASCII_8BIT, receipt.encoding
  end
end
