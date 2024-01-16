# frozen_string_literal: true

require "test_helper"

class RedisClient
  class MiddlewaresTest < Minitest::Test
    include ClientTestHelper

    def setup
      @original_module = RedisClient::Middlewares
      new_module = @original_module.dup
      RedisClient.send(:remove_const, :Middlewares)
      RedisClient.const_set(:Middlewares, new_module)
      RedisClient.register(TestMiddleware)
      super
      TestMiddleware.calls.clear
    end

    def teardown
      if @original_module
        RedisClient.send(:remove_const, :Middlewares)
        RedisClient.const_set(:Middlewares, @original_module)
      end
      TestMiddleware.calls.clear
      super
    end

    def test_call_instrumentation
      @redis.call("PING")
      assert_call [:call, :success, ["PING"], "PONG", @redis.config, 0]
    end

    def test_retried_call_instrumentation
      RedisClient.register(ErrorMiddleware)

      redis = new_client(reconnect_attempts: 1)
      redis.call("PING")

      last_call = TestMiddleware.calls.last
      assert_equal last_call, [:call, :success, ["PING"], "PONG", redis.config, 1]
    end

    def test_failing_call_instrumentation
      assert_raises CommandError do
        @redis.call("PONG")
      end
      call = TestMiddleware.calls.first
      assert_equal [:call, :error, ["PONG"]], call.first(3)
      assert_instance_of CommandError, call[3]
    end

    def test_call_once_instrumentation
      @redis.call_once("PING")
      assert_call [:call, :success, ["PING"], "PONG", @redis.config, nil]
    end

    def test_blocking_call_instrumentation
      @redis.blocking_call(nil, "PING")
      assert_call [:call, :success, ["PING"], "PONG", @redis.config, 0]
    end

    def test_pipeline_instrumentation
      @redis.pipelined do |pipeline|
        pipeline.call("PING")
      end
      assert_call [:pipeline, :success, [["PING"]], ["PONG"], @redis.config, 0]
    end

    def test_multi_instrumentation
      @redis.multi do |transaction|
        transaction.call("PING")
      end
      assert_call [
        :pipeline,
        :success,
        [["MULTI"], ["PING"], ["EXEC"]],
        ["OK", "QUEUED", ["PONG"]],
        @redis.config,
        0,
      ]
    end

    module ErrorMiddleware
      def call(command, _config, attempts = nil)
        raise ConnectionError if attempts == 0

        super
      end

      def call_pipelined(commands, _config, attempts = nil)
        raise ConnectionError if attempts == 0

        super
      end
    end

    def test_error_middleware
      second_client = new_client(middlewares: [ErrorMiddleware])
      assert_raises ConnectionError do
        second_client.call("PING")
      end
    end

    module DummyMiddleware
      def call(command, _config, _attempts = nil)
        command
      end

      def call_pipelined(commands, _config, _attempts = nil)
        commands
      end
    end

    def test_instance_middleware
      second_client = new_client(middlewares: [DummyMiddleware])
      assert_equal ["GET", "2"], second_client.call("GET", 2)
      assert_equal([["GET", "2"]], second_client.pipelined { |p| p.call("GET", 2) })
    end

    private

    def assert_call(call)
      assert_equal call, TestMiddleware.calls.first
      assert_equal 1, TestMiddleware.calls.size
    end

    def assert_calls(calls)
      assert_equal calls, TestMiddleware.calls
    end

    module TestMiddleware
      class << self
        attr_accessor :calls
      end
      @calls = []

      def connect(config)
        result = super
        TestMiddleware.calls << [:connect, :success, result, config]
        result
      rescue => error
        TestMiddleware.calls << [:connect, :error, error, config]
        raise
      end

      def call(command, config, attempts = nil)
        result = super
        TestMiddleware.calls << [:call, :success, command, result, config, attempts]
        result
      rescue => error
        TestMiddleware.calls << [:call, :error, command, error, config, attempts]
        raise
      end

      def call_pipelined(commands, config, attempts = nil)
        result = super
        TestMiddleware.calls << [:pipeline, :success, commands, result, config, attempts]
        result
      rescue => error
        TestMiddleware.calls << [:pipeline, :error, commands, error, config, attempts]
        raise
      end
    end
  end
end
