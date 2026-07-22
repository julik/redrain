# frozen_string_literal: true

# Ruby client for Rain's Issuing API. Port of the official Python SDK
# (https://github.com/SignifyHQ/rain-sdk-python). Not affiliated with
# Signify Holdings, Inc.
#
#   rain = Redrain::Client.new(api_key: ENV.fetch("RAIN_API_KEY"), environment: :production)
#   rain.users.list(limit: 10)
module Redrain
end

require "redrain/version"
require "redrain/errors"
require "redrain/upload"
require "redrain/http_client"
require "redrain/model"
require "redrain/models"
require "redrain/page"
require "redrain/resource"
require "redrain/client"
require "redrain/resources"
