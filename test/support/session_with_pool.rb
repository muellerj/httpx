# frozen_string_literal: true

module SessionWithPool
  ConnectionPool = Class.new(HTTPX::Pool) do
    attr_reader :resolver, :connections, :selector
    attr_reader :connection_count
    attr_reader :ping_count

    def initialize(*)
      super
      @connection_count = 0
      @ping_count = 0
    end

    def init_connection(connection, _)
      super
      connection.on(:open) { @connection_count += 1 }
      connection.on(:pong) { @ping_count += 1 }
    end

    def selectable_count
      @selector.instance_variable_get(:@selectables).size
    end

    def find_resolver_for(*args, &blk)
      @resolver = super(*args, &blk)
      @resolver
    end
  end

  module InstanceMethods
    attr_reader :connection_exausted

    def pool
      @pool ||= ConnectionPool.new
    end

    def set_connection_callbacks(connection, connections, options)
      super
      connection.on(:exhausted) do
        @connection_exausted = true
      end
    end
  end

  module ConnectionMethods
    attr_reader :origins

    def set_parser_callbacks(parser)
      super
      parser.on(:pong) { emit(:pong) }
    end
  end
end
