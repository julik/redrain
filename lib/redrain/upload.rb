# frozen_string_literal: true

require "pathname"

module Redrain
  # A file destined for one of Rain's multipart upload endpoints.
  #
  # You rarely construct this directly — the upload methods coerce whatever you
  # hand them:
  #
  #   rain.disputes.evidence.upload(id, evidence: File.open("receipt.pdf"))
  #   rain.disputes.evidence.upload(id, evidence: Pathname("receipt.pdf"))
  #   rain.disputes.evidence.upload(id, evidence: "raw bytes")
  #
  # Reach for the explicit form when the filename or content type matters and
  # can't be inferred — an in-memory PDF, say:
  #
  #   Redrain::Upload.new(bytes, filename: "receipt.pdf", content_type: "application/pdf")
  class Upload
    # @return [String] used when the extension tells us nothing
    DEFAULT_CONTENT_TYPE = "application/octet-stream"

    # Deliberately small. Rain accepts identity documents and receipts; anything
    # exotic can pass content_type: explicitly.
    CONTENT_TYPES = {
      ".png"  => "image/png",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif"  => "image/gif",
      ".webp" => "image/webp",
      ".heic" => "image/heic",
      ".tif"  => "image/tiff",
      ".tiff" => "image/tiff",
      ".pdf"  => "application/pdf",
      ".txt"  => "text/plain",
      ".csv"  => "text/csv",
      ".json" => "application/json",
      ".mp4"  => "video/mp4",
      ".mov"  => "video/quicktime"
    }.freeze

    # @return [String] name sent in the multipart Content-Disposition
    attr_reader :filename

    # @return [String] MIME type sent for this part
    attr_reader :content_type

    # @param content [String, IO] the bytes, or something that reads them
    # @param filename [String, nil] defaults to "file"
    # @param content_type [String, nil] inferred from the filename when omitted
    def initialize(content, filename: nil, content_type: nil)
      @content      = content
      @filename     = filename || "file"
      @content_type = content_type || self.class.content_type_for(@filename)
    end

    # Anything already an Upload passes through untouched.
    #
    # @param value [Redrain::Upload, File, Pathname, IO, String]
    # @return [Redrain::Upload]
    # @raise [ArgumentError] if the value isn't something we can read bytes from
    def self.coerce(value)
      case value
      when Upload   then value
      when Pathname then from_path(value)
      when File     then new(value, filename: File.basename(value.path))
      when IO, StringIO
        # A bare IO has no name to borrow, so the default filename stands.
        new(value)
      when String   then new(value)
      else
        raise ArgumentError,
          "expected a File, Pathname, IO, String or Redrain::Upload, got #{value.class}"
      end
    end

    # @param path [String, Pathname]
    # @return [Redrain::Upload]
    def self.from_path(path)
      path = Pathname(path)
      new(path.binread, filename: path.basename.to_s)
    end

    # @param filename [String]
    # @return [String] MIME type guessed from the extension
    def self.content_type_for(filename)
      CONTENT_TYPES.fetch(File.extname(filename.to_s).downcase, DEFAULT_CONTENT_TYPE)
    end

    # Read eagerly and memoise. Rain caps uploads at 20 MB, so holding the bytes
    # is cheap — and a retried request rebuilds the multipart body from scratch,
    # which would otherwise re-read an exhausted IO and upload nothing.
    #
    # @return [String] the bytes, in binary encoding
    def read
      @read ||= begin
        if @content.is_a?(String)
          @content
        else
          @content.binmode if @content.respond_to?(:binmode)
          @content.read
        end.b
      end
    end
  end
end
