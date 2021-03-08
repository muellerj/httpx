# frozen_string_literal: true

require "forwardable"
require "timers"
require "httpx/selector"
require "httpx/connection"
require "httpx/resolver"

module HTTPX
  class Pool
    extend Forwardable

    def_delegator :@timers, :after

    def initialize
      @resolvers = {}
      @_resolver_ios = {}
      @timers = Timers::Group.new
      @selector = Selector.new
      @connections = []
      @connected_connections = 0
    end

    def empty?
      @connections.empty?
    end

    def next_tick
      catch(:jump_tick) do
        timeout = [next_timeout, @timers.wait_interval].compact.min
        if timeout && timeout.negative?
          @timers.fire
          throw(:jump_tick)
        end

        @selector.select(timeout, &:call)

        @timers.fire
      end
    rescue StandardError => e
      @connections.each do |connection|
        connection.emit(:error, e)
      end
    rescue Exception # rubocop:disable Lint/RescueException
      @connections.each(&:reset)
      raise
    end

    def close(connections = @connections)
      return if connections.empty?

      @timers.cancel
      connections = connections.reject(&:inflight?)
      connections.each(&:close)
      next_tick until connections.none? { |c| c.state != :idle && @connections.include?(c) }
      @resolvers.each_value do |resolver|
        resolver.close unless resolver.closed?
      end if @connections.empty?
    end

    def init_connection(connection, _options)
      resolve_connection(connection)
      connection.timers = @timers
      connection.on(:open) do
        @connected_connections += 1
      end
      connection.on(:unreachable) do
        resolver = find_resolver_for(connection)
        resolver.uncache(connection) if resolver
        resolve_connection(connection)
      end
    end

    # opens a connection to the IP reachable through +uri+.
    # Many hostnames are reachable through the same IP, so we try to
    # maximize pipelining by opening as few connections as possible.
    #
    def find_connection(uri, options)
      @connections.find do |connection|
        connection.match?(uri, options)
      end
    end

    private

    def resolve_connection(connection)
      @connections << connection unless @connections.include?(connection)

      if connection.addresses || connection.state == :open
        #
        # there are two cases in which we want to activate initialization of
        # connection immediately:
        #
        # 1. when the connection already has addresses, i.e. it doesn't need to
        #    resolve a name (not the same as name being an IP, yet)
        # 2. when the connection is initialized with an external already open IO.
        #
        on_resolver_connection(connection)
        return
      end

      resolver = find_resolver_for(connection)
      resolver << connection
      return if resolver.empty?

      @_resolver_ios[resolver] ||= @selector.register(resolver)
    end

    def on_resolver_connection(connection)
      found_connection = @connections.find do |ch|
        ch != connection && ch.mergeable?(connection)
      end
      return register_connection(connection) unless found_connection

      if found_connection.state == :open
        coalesce_connections(found_connection, connection)
        throw(:coalesced, found_connection)
      else
        found_connection.once(:open) do
          coalesce_connections(found_connection, connection)
        end
      end
    end

    def on_resolver_error(connection, error)
      connection.emit(:error, error)
      # must remove connection by hand, hasn't been started yet
      unregister_connection(connection)
    end

    def on_resolver_close(resolver)
      resolver_type = resolver.class
      return unless @resolvers[resolver_type] == resolver

      @resolvers.delete(resolver_type)

      @selector.deregister(resolver)
      @_resolver_ios.delete(resolver)
      resolver.close unless resolver.closed?
    end

    def register_connection(connection)
      if connection.state == :open
        # if open, an IO was passed upstream, therefore
        # consider it connected already.
        @connected_connections += 1
      end
      @selector.register(connection)
      connection.on(:close) do
        unregister_connection(connection)
      end
    end

    def unregister_connection(connection)
      @connections.delete(connection)
      @selector.deregister(connection)
      @connected_connections -= 1
    end

    def coalesce_connections(conn1, conn2)
      if conn1.coalescable?(conn2)
        conn1.merge(conn2)
        @connections.delete(conn2)
      else
        register_connection(conn2)
      end
    end

    def next_timeout
      @resolvers.values.reject(&:closed?).map(&:timeout).compact.min || @connections.map(&:timeout).compact.min
    end

    def find_resolver_for(connection)
      connection_options = connection.options
      resolver_type = connection_options.resolver_class
      resolver_type = Resolver.registry(resolver_type) if resolver_type.is_a?(Symbol)

      @resolvers[resolver_type] ||= begin
        resolver = resolver_type.new(connection_options)
        resolver.on(:resolve, &method(:on_resolver_connection))
        resolver.on(:error, &method(:on_resolver_error))
        resolver.on(:close) { on_resolver_close(resolver) }
        resolver
      end
    end
  end
end
