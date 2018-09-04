# frozen_string_literal: true

module HTTPX
  module Plugins
    module Retries
      MAX_RETRIES = 3
      IDEMPOTENT_METHODS = %i[get options head put delete].freeze

      module InstanceMethods
        def max_retries(n)
          branch(default_options.with_max_retries(n.to_i))
        end

        private

        def fetch_response(request)
          response = super
          if response.is_a?(ErrorResponse) &&
             request.retries.positive? &&
             IDEMPOTENT_METHODS.include?(request.verb)
            request.retries -= 1
            channel = find_channel(request)
            channel.send(request)
            return
          end
          response
        end
      end

      module RequestMethods
        attr_accessor :retries

        def initialize(*args)
          super
          @retries = @options.max_retries || MAX_RETRIES
        end
      end

      module OptionsMethods
        def self.included(klass)
          super
          klass.def_option(:max_retries) do |num|
            num = Integer(num)
            raise Error, ":max_retries must be positive" unless num.positive?
            num
          end
        end
      end
    end
    register_plugin :retries, Retries
  end
end