# frozen_string_literal: true

require "httpx/version"

require "httpx/errors"
require "httpx/callbacks"
require "httpx/registry"
require "httpx/transcoder"
require "httpx/options"
require "httpx/timeout"
require "httpx/connection"
require "httpx/headers"
require "httpx/request"
require "httpx/response"
require "httpx/client"

module HTTPX
  # All plugins should be stored under this module/namespace. Can register and load
  # plugins.
  #
  module Plugins
    @plugins = {}

    # Loads a plugin based on a name. If the plugin hasn't been loaded, tries to load
    # it from the load path under "httpx/plugins/" directory.
    #
    def self.load_plugin(name)
      h = @plugins
      unless (plugin = h[name])
        require "httpx/plugins/#{name}"
        raise "Plugin #{name} hasn't been registered" unless (plugin = h[name])
      end
      plugin
    end

    # Registers a plugin (+mod+) in the central store indexed by +name+.
    #
    def self.register_plugin(name, mod)
      @plugins[name] = mod
    end
  end

end
