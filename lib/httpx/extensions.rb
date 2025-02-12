# frozen_string_literal: true

require "uri"

module HTTPX
  unless Method.method_defined?(:curry)

    # Backport
    #
    # Ruby 2.1 and lower implement curry only for Procs.
    #
    # Why not using Refinements? Because they don't work for Method (tested with ruby 2.1.9).
    #
    module CurryMethods
      # Backport for the Method#curry method, which is part of ruby core since 2.2 .
      #
      def curry(*args)
        to_proc.curry(*args)
      end
    end
    Method.__send__(:include, CurryMethods)
  end

  unless String.method_defined?(:+@)
    # Backport for +"", to initialize unfrozen strings from the string literal.
    #
    module LiteralStringExtensions
      def +@
        frozen? ? dup : self
      end
    end
    String.__send__(:include, LiteralStringExtensions)
  end

  unless Numeric.method_defined?(:positive?)
    # Ruby 2.3 Backport (Numeric#positive?)
    #
    module PosMethods
      def positive?
        self > 0
      end
    end
    Numeric.__send__(:include, PosMethods)
  end

  unless Numeric.method_defined?(:negative?)
    # Ruby 2.3 Backport (Numeric#negative?)
    #
    module NegMethods
      def negative?
        self < 0
      end
    end
    Numeric.__send__(:include, NegMethods)
  end

  module NumericExtensions
    # Ruby 2.4 backport
    refine Numeric do
      def infinite?
        self == Float::INFINITY
      end unless Numeric.method_defined?(:infinite?)
    end
  end

  module StringExtensions
    refine String do
      # Ruby 2.5 backport
      def delete_suffix!(suffix)
        suffix = Backports.coerce_to_str(suffix)
        chomp! if frozen?
        len = suffix.length
        if len > 0 && index(suffix, -len)
          self[-len..-1] = ''
          self
        else
          nil
        end
      end unless String.method_defined?(:delete_suffix!)
    end
  end

  module HashExtensions
    refine Hash do
      # Ruby 2.4 backport
      def compact
        h = {}
        each do |key, value|
          h[key] = value unless value == nil
        end
        h
      end unless Hash.method_defined?(:compact)
    end
  end

  module ArrayExtensions
    module FilterMap
      refine Array do
        # Ruby 2.7 backport
        def filter_map
          return to_enum(:filter_map) unless block_given?

          each_with_object([]) do |item, res|
            processed = yield(item)
            res << processed if processed
          end
        end
      end unless Array.method_defined?(:filter_map)
    end

    module Sum
      refine Array do
        # Ruby 2.6 backport
        def sum(accumulator = 0, &block)
          values = block_given? ? map(&block) : self
          values.inject(accumulator, :+)
        end
      end unless Array.method_defined?(:sum)
    end

    module Intersect
      refine Array do
        # Ruby 3.1 backport
        def intersect?(arr)
          if size < arr.size
            smaller = self
          else
            smaller, arr = arr, self
          end
          (arr & smaller).size > 0
        end
      end unless Array.method_defined?(:intersect?)
    end
  end

  module IOExtensions
    refine IO do
      # Ruby 2.3 backport
      # provides a fallback for rubies where IO#wait isn't implemented,
      # but IO#wait_readable and IO#wait_writable are.
      def wait(timeout = nil, _mode = :read_write)
        r, w = IO.select([self], [self], nil, timeout)

        return unless r || w

        self
      end unless IO.method_defined?(:wait) && IO.instance_method(:wait).arity == 2
    end
  end

  module RegexpExtensions
    refine(Regexp) do
      # Ruby 2.4 backport
      def match?(*args)
        !match(*args).nil?
      end
    end
  end

  module URIExtensions
    # uri 0.11 backport, ships with ruby 3.1
    refine URI::Generic do

      def non_ascii_hostname
        @non_ascii_hostname
      end

      def non_ascii_hostname=(hostname)
        @non_ascii_hostname = hostname
      end

      def authority
        return host if port == default_port

        "#{host}:#{port}"
      end unless URI::HTTP.method_defined?(:authority)

      def origin
        "#{scheme}://#{authority}"
      end unless URI::HTTP.method_defined?(:origin)

      def altsvc_match?(uri)
        uri = URI.parse(uri)

        origin == uri.origin || begin
          case scheme
          when "h2"
            (uri.scheme == "https" || uri.scheme == "h2") &&
            host == uri.host &&
            (port || default_port) == (uri.port || uri.default_port)
          else
            false
          end
        end
      end
    end
  end
end
