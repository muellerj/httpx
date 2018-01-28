# frozen_string_literal: true

require "socket"
require "openssl"
require "ipaddr"

module HTTPX
  class TCP
    include Loggable

    attr_reader :ip, :port

    def initialize(hostname, port, options)
      @state = :idle
      @options = Options.new(options)
      @fallback_protocol = @options.fallback_protocol
      @ip = TCPSocket.getaddress(hostname) 
      @port = port
      if @options.io
        @io = case @options.io
        when Hash
          @options.io[@ip] || @options.io["#{@ip}:#{@port}"]
        else
          @options.io
        end
        unless @io.nil?
          @keep_open = true 
          @state = :connected
        end
      end
      @io ||= build_socket 
    end

    def scheme
      "http"
    end

    def to_io
      @io.to_io
    end

    def protocol
      @fallback_protocol 
    end

    def connect
      return unless closed?
      begin
        if @io.closed?
          transition(:idle) 
          @io = build_socket
        end
        @io.connect_nonblock(Socket.sockaddr_in(@port, @ip))
      rescue Errno::EISCONN
      end
      transition(:connected)

    rescue Errno::EINPROGRESS,
           Errno::EALREADY,
           ::IO::WaitReadable
    end

    if RUBY_VERSION < "2.3"
      def read(size, buffer)
        @io.read_nonblock(size, buffer)
        buffer.bytesize
      rescue ::IO::WaitReadable
        0
      rescue EOFError
        nil
      end

      def write(buffer)
        siz = @io.write_nonblock(buffer)
        buffer.slice!(0, siz)
        siz
      rescue ::IO::WaitWritable
        0
      rescue EOFError
        nil
      end
    else
      def read(size, buffer)
        ret = @io.read_nonblock(size, buffer, exception: false)
        return 0 if ret == :wait_readable
        return if ret.nil?
        buffer.bytesize
      end

      def write(buffer)
        siz = @io.write_nonblock(buffer, exception: false)
        return 0 if siz == :wait_writable
        return if siz.nil?
        buffer.slice!(0, siz)
        siz
      end
    end

    def close
      return if @keep_open || closed?
      begin
        @io.close
      ensure
        transition(:closed)
      end
    end

    def connected?
      @state == :connected
    end

    def closed?
      @state == :idle || @state == :closed
    end

    def inspect
      id = @io.closed? ? "closed" : @io.fileno
      "#<TCP(fd: #{id}): #{@ip}:#{@port} (state: #{@state})>"
    end

    private

    def build_socket
      addr = IPAddr.new(@ip)
      Socket.new(addr.family, :STREAM, 0)
    end

    def transition(nextstate)
      case nextstate
      when :idle
      when :connected
        return unless @state == :idle
      when :closed
        return unless @state == :connected
      end
      log(1, "#{inspect}: ") { nextstate.to_s }
      @state = nextstate
    end
  end

  class SSL < TCP
    TLS_OPTIONS = OpenSSL::SSL::SSLContext.instance_methods.include?(:alpn_protocols) ? 
        { alpn_protocols: %w[h2 http/1.1] } : {}

    def initialize(_, _, options)
      @ctx = OpenSSL::SSL::SSLContext.new
      @ctx.set_params(TLS_OPTIONS.merge(options.ssl))
      super
      @state = :negotiated if @keep_open
    end

    def scheme
      "https"
    end

    def protocol
      @io.alpn_protocol
    rescue
      super
    end

    def close
      super
      # allow reconnections
      # connect only works if initial @io is a socket
      @io = @io.io if @io.respond_to?(:io)
      @negotiated = false
    end

    def connect
      super
      if @keep_open
        @state = :negotiated
        return
      end
      return if @state == :negotiated ||
                @state != :connected
      @io = OpenSSL::SSL::SSLSocket.new(@io, @ctx)
      @io.hostname = @hostname
      @io.sync_close = true
      @io.connect
      transition(:negotiated)
    end


    if RUBY_VERSION < "2.3"
      def read(*)
        super
      rescue ::IO::WaitWritable
        0
      end
      
      def write(*)
        super
      rescue ::IO::WaitReadable
        0
      end
    else
      if OpenSSL::VERSION < "2.0.6"
        def read(size, buffer)
          @io.read_nonblock(size, buffer)
          buffer.bytesize
        rescue ::IO::WaitReadable,
               ::IO::WaitWritable
          0
        rescue EOFError
          nil
        end
      end
    end

    def inspect
      id = @io.closed? ? "closed" : @io.to_io.fileno
      "#<SSL(fd: #{id}): #{@ip}:#{@port} state: #{@state}>"
    end

    private

    def transition(nextstate)
      case nextstate
      when :negotiated
        return unless @state == :connected
      when :closed
        return unless @state == :negotiated ||
                      @state == :connected
      end
      super
    end
  end
  module IO
    extend Registry
    register "tcp", TCP
    register "ssl", SSL
  end
end
