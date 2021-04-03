# frozen_string_literal: true

require './lib/db'
require './lib/http_server'
require './lib/discord_bot'
require './lib/twitch_bot'

require 'pp'

require "./CONFIG"

DB = Database.new DB_CONF
HTTPServer.config HTTP_SERVER_CONF

DC = DiscordBot.new DISCORD_BOT_CONF
TWITCH = TwitchBot.new TWITCH_BOT_CONF, HTTP_SERVER_CONF, DB, HTTPServer

#HTTPServer.run!
#DC.run
TWITCH.test
