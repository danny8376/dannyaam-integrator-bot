# frozen_string_literal: true

require 'eventmachine'
require 'sinatra/base'
require 'sinatra/namespace'
#require 'rack/fiber_pool'
require 'rack-timeout'

# ==== Prefixed Fiber Pool ====
module Rack
=begin
  class PrefixedFiberPool
    def initialize(app, options = {})
      @app = app
      @mapping = []
      @rescue_exception = options[:rescue_exception] || proc do |env, e|
        [500, {}, ["#{e.class.name}: #{e.message.to_s}"]]
      end
      remap options[:map] if options[:map]
    end

    def remap(map)
      @mapping = map.map { |location, pool_size|
        location = location.chomp('/')
        match = Regexp.new("^#{Regexp.quote(location).gsub('/', '/+')}(.*)", nil, 'n')

        [location, match, FiberPool.new(@app, size: pool_size)]
      }.sort_by { |(location, _, _)| -location.size }
      pp @mapping
    end

    def call(env)
      @mapping.each do |location, match, pool|
        next unless m = match.match(env[PATH_INFO].to_s)

        rest = m[1]
        next unless !rest || rest.empty? || rest[0] == ?/

        return pool.call(env)
      end

      [500, { CONTENT_TYPE => "text/plain", "X-Cascade" => "pass" }, ["No pool for path: #{env[PATH_INFO]}"]]
    end
  end
=end
end

# ==== HTTP/Webhook Server ====

class HTTPServer < Sinatra::Base
  register Sinatra::Namespace

  @@twitch_callback = nil

  def self.config(conf, sys)
    @@conf = conf
    @@sys = sys

    #use Rack::PrefixedFiberPool, map: {
    #  "#{@@conf[:prefix]}" => 100,
    #  "#{@@conf[:prefix]}/twitch/webhook" => 100,
    #}
    use Rack::Timeout, service_timeout: 5

    configure do
      set :server, 'thin'
      set :bind, @@conf[:bind]
      set :port, @@conf[:port]
      set :server_settings, { signals: false } if EM.reactor_running?
      set :logging, $log_level == :debug
    end

    namespace @@conf[:prefix] do
      namespace "/twitch" do
        post "/webhook" do
          body = JSON.parse(request.body.read) rescue {}
          request.body.rewind

          @@sys.queue.push(:twitch, {
            type: :webhook,
            data: {
              headers: headers,
              body: body,
              request: request,
              server: self,
              callback: proc { |res|
                EM.next_tick do
                  res = [200, {}, res] if res.is_a? String
                  res = [res, {}, nil] if res.is_a? Integer
                  res = res.insert(1, {}) if res.is_a? Array and res.size == 2
                  env['async.callback'].call res
                end
              }
            }
          })

          throw :async
        end
      end
    end
  end
end

