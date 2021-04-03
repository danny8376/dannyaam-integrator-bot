# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/namespace'

# ==== HTTP/Webhook Server ====

class HTTPServer < Sinatra::Base
  register Sinatra::Namespace

  @@twitch_callback = nil

  def self.config(conf)
    @@conf = conf

    configure do
      set :server, 'thin'
      set :bind, @@conf[:bind]
      set :port, @@conf[:port]
    end

    namespace @@conf[:prefix] do
      namespace "/twitch" do
        post "/webhook" do
          body = JSON.parse(request.body.read) rescue {}
          request.body.rewind

          if @@twitch_callback
            @@twitch_callback.call headers, body, self
          else
            [404, "no backend"]
          end
        end
      end
    end
  end

  def self.twitch_webhook
    @@twitch_callbacks = proc do |*args|
      yield *args
    end
  end
end

