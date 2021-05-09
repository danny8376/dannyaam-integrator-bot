# frozen_string_literal: true

require 'eventmachine'
require 'async-rack' # must before any rack things
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
      enable :sessions
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
              callback: proc { |res| async_callback { res } }
            }
          })
          throw :async
        end

        get "/oauth/callback" do
          code = params['code']
          if code
            @@sys.queue.push(:twitch, {
              type: :oauth_callback,
              data: {
                code: code,
                callback: proc { |userid|
                  async_callback {
                    if userid
                      twitch_logged_in userid
                    else
                      "Bad Login"
                    end
                  }
                }
              }
            })
            throw :async
          else
            "Bad Login"
          end
        end

        get "/login" do
          if twitch_check_login
            "Nothing Now, Currently logged in as #{session[:twitch_login_userid]}"
          end
        end

      end
    end
  end

  def twitch_check_login
    userid = session[:twitch_login_userid]
    if userid
      true
    else
      session[:twitch_login_back] = request.path_info
      @@sys.queue.push(:twitch, {
        type: :login,
        data: {
          callback: proc { |uri: nil, userid: nil|
            async_callback {
              redirect uri if uri
              twitch_logged_in userid if userid
            }
          }
        }
      })
      throw :async
    end
  end

  def twitch_logged_in(userid)
    session[:twitch_login_userid] = userid
    back_uri = session[:twitch_login_back]
    session[:twitch_login_back] = nil
    redirect back_uri
  end

  def async_callback
    EM.next_tick {
      invoke { yield }
      env['async.callback'].call response.finish
    }
  end
end

