# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class UploadTest < Minitest::Test
  def test_coerces_a_string_to_bytes_with_a_generic_name
    upload = Redrain::Upload.coerce("bytes")

    assert_equal "bytes", upload.read
    assert_equal "file", upload.filename
    assert_equal "application/octet-stream", upload.content_type
  end

  def test_borrows_the_filename_and_type_from_a_file
    Tempfile.create(["passport", ".png"]) do |file|
      file.write("PNG")
      file.rewind

      upload = Redrain::Upload.coerce(file)

      assert_equal "PNG", upload.read
      assert_match(/\Apassport.*\.png\z/, upload.filename)
      assert_equal "image/png", upload.content_type
    end
  end

  def test_reads_a_pathname_from_disk
    Tempfile.create(["receipt", ".pdf"]) do |file|
      file.write("%PDF")
      file.flush

      upload = Redrain::Upload.coerce(Pathname(file.path))

      assert_equal "%PDF", upload.read
      assert_equal "application/pdf", upload.content_type
    end
  end

  def test_accepts_an_explicit_filename_and_content_type
    upload = Redrain::Upload.new("data", filename: "scan.tiff", content_type: "image/x-custom")

    assert_equal "scan.tiff", upload.filename
    assert_equal "image/x-custom", upload.content_type
  end

  def test_infers_the_content_type_from_the_extension
    assert_equal "image/jpeg", Redrain::Upload.new("d", filename: "a.JPG").content_type
    assert_equal "application/octet-stream", Redrain::Upload.new("d", filename: "a.xyz").content_type
  end

  def test_passes_an_upload_through_untouched
    upload = Redrain::Upload.new("d", filename: "a.pdf")

    assert_same upload, Redrain::Upload.coerce(upload)
  end

  def test_rejects_things_it_cannot_read
    assert_raises(ArgumentError) { Redrain::Upload.coerce(42) }
  end

  def test_uploads_reach_the_endpoint_as_multipart
    stub_request(:put, "#{TEST_BASE_URL}/disputes/d-1/evidence").to_return(status: 204)
    client = Redrain::Client.new(api_key: TEST_API_KEY, environment: :dev)

    result = client.disputes.evidence.upload(
      "d-1",
      name: "Receipt",
      type: "receipt",
      evidence: Redrain::Upload.new("EVIDENCE", filename: "proof.pdf")
    )

    assert_nil result
    assert_requested(:put, "#{TEST_BASE_URL}/disputes/d-1/evidence") { |request|
      assert_includes request.body, %(name="name")
      assert_includes request.body, "Receipt"
      assert_includes request.body, %(filename="proof.pdf")
      assert_includes request.body, "EVIDENCE"
      true
    }
  end

  def test_reading_twice_returns_the_same_bytes
    upload = Redrain::Upload.coerce(StringIO.new("PAYLOAD"))

    assert_equal "PAYLOAD", upload.read
    assert_equal "PAYLOAD", upload.read, "a retried request re-reads the upload"
  end

  def test_read_always_returns_binary
    assert_equal Encoding::ASCII_8BIT, Redrain::Upload.new("café").read.encoding
  end
end
