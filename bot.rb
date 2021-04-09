# frozen_string_literal: true

require 'eventmachine'

require './lib/db'
require './lib/task_queue'
require './lib/http_server'
require './lib/discord_bot'
require './lib/twitch_bot'

require 'pp'

require "./CONFIG"

Faraday.default_adapter = :em_http

$log_level = (ENV['APP_ENV'] == "development" or ENV['APP_ENV'].nil?) ? :debug : :info

db = Database.new DB_CONF
tq = TaskQueue.new
Sys = Struct.new(:db, :queue, :http).new(db, tq, HTTPServer)

EM.run do
  Signal.trap("INT")  { EventMachine.stop }
  Signal.trap("TERM") { EventMachine.stop }

  # HTTP
  HTTPServer.config HTTP_SERVER_CONF, Sys
  HTTPServer.run!

  # Discord bot
  # actually threaded, but placed here for tidiness
  DC = DiscordBot.new DISCORD_BOT_CONF, Sys
  DC.run

  # Twitch bot
  TWITCH = TwitchBot.new TWITCH_BOT_CONF, HTTP_SERVER_CONF, Sys
  TWITCH.test
end

