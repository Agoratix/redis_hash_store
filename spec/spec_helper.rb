# frozen_string_literal: true

require "bundler/setup"
require "active_support"
require "redis_hash_store"
require "fake_app"
require "mock_redis"

class MockRedis
  def with
    yield self
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.order = "random"

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.before(:each) do
    mock_redis = MockRedis.new
    allow(Redis).to receive(:new).and_return(mock_redis)
  end

  config.after do
    Rails.cache.clear
  end
end
