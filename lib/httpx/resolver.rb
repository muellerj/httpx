# frozen_string_literal: true

require "resolv"
require "ipaddr"

module HTTPX
  module Resolver
    extend Registry

    RESOLVE_TIMEOUT = 5

    require "httpx/resolver/resolver"
    require "httpx/resolver/system"
    require "httpx/resolver/native"
    require "httpx/resolver/https"
    require "httpx/resolver/multi"

    register :system, System
    register :native, Native
    register :https,  HTTPS

    @lookup_mutex = Mutex.new
    @lookups = Hash.new { |h, k| h[k] = [] }

    @identifier_mutex = Mutex.new
    @identifier = -1
    @system_resolver = Resolv::Hosts.new

    module_function

    def nolookup_resolve(hostname)
      ip_resolve(hostname) || cached_lookup(hostname) || system_resolve(hostname)
    end

    def ip_resolve(hostname)
      [IPAddr.new(hostname)]
    rescue ArgumentError
    end

    def system_resolve(hostname)
      ips = if in_ractor?
        Ractor.current[:httpx_system_resolver] ||= Resolv::Hosts.new
      else
        @system_resolver
      end.getaddresses(hostname)

      return if ips.empty?

      ips.map { |ip| IPAddr.new(ip) }
    rescue IOError
    end

    def cached_lookup(hostname)
      ttl = Utils.now
      lookup_synchronize do |lookups|
        if lookups.key?(hostname)

          lookups[hostname] = lookups[hostname].select do |address|
            address["TTL"] > ttl
          end

          ips = lookups[hostname].flat_map do |address|
            if address.key?("alias")
              lookup(address["alias"], ttl)
            else
              IPAddr.new(address["data"])
            end
          end
          ips unless ips.empty?
        end
      end
    end

    def cached_lookup_set(hostname, family, entries)
      now = Utils.now
      entries.each do |entry|
        entry["TTL"] += now
      end
      lookup_synchronize do |lookups|
        case family
        when Socket::AF_INET6
          lookups[hostname].concat(entries)
        when Socket::AF_INET
          lookups[hostname].unshift(*entries)
        end
        entries.each do |entry|
          next unless entry["name"] != hostname

          case family
          when Socket::AF_INET6
            lookups[entry["name"]] << entry
          when Socket::AF_INET
            lookups[entry["name"]].unshift(entry)
          end
        end
      end
    end

    def generate_id
      if in_ractor?
        identifier = Ractor.current[:httpx_resolver_identifier] ||= -1
        return (Ractor.current[:httpx_resolver_identifier] = (identifier + 1) & 0xFFFF)
      end

      @identifier_mutex.synchronize do
        @identifier = (@identifier + 1) & 0xFFFF
      end
    end

    def encode_dns_query(hostname, type: Resolv::DNS::Resource::IN::A)
      Resolv::DNS::Message.new(generate_id).tap do |query|
        query.rd = 1
        query.add_question(hostname, type)
      end.encode
    end

    def decode_dns_answer(payload)
      message = Resolv::DNS::Message.decode(payload)
      addresses = []
      message.each_answer do |question, _, value|
        case value
        when Resolv::DNS::Resource::IN::CNAME
          addresses << {
            "name" => question.to_s,
            "TTL" => value.ttl,
            "alias" => value.name.to_s,
          }
        when Resolv::DNS::Resource::IN::A,
             Resolv::DNS::Resource::IN::AAAA
          addresses << {
            "name" => question.to_s,
            "TTL" => value.ttl,
            "data" => value.address.to_s,
          }
        end
      end
      addresses
    end

    def lookup_synchronize
      if in_ractor?
        lookups = Ractor.current[:httpx_resolver_lookups] ||= Hash.new { |h, k| h[k] = [] }
        return yield(lookups)
      end

      @lookup_mutex.synchronize { yield(@lookups) }
    end

    def id_synchronize
      @identifier_mutex.synchronize { yield(@identifier) }
    end

    if defined?(Ractor) &&
       # no ractor support for 3.0
       RUBY_VERSION >= "3.1.0"
      def in_ractor?
        Ractor.main != Ractor.current
      end
    else
      def in_ractor?
        false
      end
    end
  end
end
