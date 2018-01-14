# frozen_string_literal: true

module HTTPX
  module Plugins
    module Compression
      ACCEPT_ENCODING = %w[gzip deflate].freeze

      def self.configure(klass, *)
        klass.plugin(:"compression/gzip")
        klass.plugin(:"compression/deflate")
      end

      module RequestMethods
        def initialize(*)
          super
          ACCEPT_ENCODING.each do |enc|
            @headers.add("accept-encoding", enc)
          end
        end
      end

      module ResponseBodyMethods
        def initialize(*)
          super
          @_decoders = @headers.get("content-encoding").map do |encoding|
            Transcoder.registry(encoding)
          end
        end

        def write(*)
          super
          if @length == @headers["content-length"].to_i
            @buffer.rewind
            @buffer = decompress(@buffer)
          end
        end

        private

        def decompress(buffer)
          @_decoders.reverse_each do |decoder|
            buffer = decoder.decode(buffer)
          end
          buffer
        end 
      end

      class CompressEncoder
        attr_reader :content_type

        def initialize(raw)
          @content_type = raw.content_type
          @raw = raw.respond_to?(:read) ? raw : StringIO.new(raw.to_s)
          @buffer = StringIO.new("".b, File::RDWR)
        end

        def each(&blk)
          return enum_for(__method__) unless block_given?
          unless @buffer.size.zero?
            @buffer.rewind
            return @buffer.each(&blk)
          end
          compress(&blk)
        end

        def to_s
          compress
          @buffer.rewind
          @buffer.read
        end

        def bytesize
          compress
          @buffer.size
        end

        def close
          # @buffer.close
        end
      end

    end
    register_plugin :compression, Compression
  end


end