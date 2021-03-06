ENV["BLACK_SWAN_DATABASE_URL"] = "postgres://localhost/black-swan-development"
ENV["FORCE_SSL"]               = "false"
ENV["LIBRATO_TOKEN"]           = "secret"
ENV["LIBRATO_USER"]            = "org"
# make sure to set RACK_ENV=test before requiring Sinatra
ENV["RACK_ENV"]                = "test"
ENV["RELEASE"]                 = "1"

require 'bundler/setup'
Bundler.require(:default, :test)

require "minitest/spec"
require "minitest/autorun"
require "rr"

# suppress logging
unless ENV["TEST_LOGS"] == "true"
  module Slides
    def self.log(*_)
      yield if block_given?
    end
  end
end

DB = Sequel.connect(ENV["BLACK_SWAN_DATABASE_URL"])
Slim::Embedded.options[:markdown] = {}

require_relative "../lib/org"

class MiniTest::Spec
  include RR::Adapters::TestUnit
end
