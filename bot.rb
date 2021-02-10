# frozen_string_literal: true

require 'discordrb'
require 'pp'

require "./CONFIG"

bot = Discordrb::Bot.new token: BOT_TOKEN

puts "This bot's invite URL is #{bot.invite_url}."
puts 'Click on it to invite it to your server.'

ROLE_CACHE = {} # userid => [{guild, role}, ...]
ROLE_CACHE.default_proc = proc { |h, k| h[k] = [] }

REACTION_ROLE_KEY = Struct.new(:guild, :ch, :msg, :emote)
REACTION_ROLES = {}
REACTION_ROLES_CONF.each do |val|
  REACTION_ROLES[REACTION_ROLE_KEY.new(*val.values_at(:guild, :ch, :msg, :emote))] = val.slice(:guild, :role, :remove)
end

bot.ready do
  bot.servers.each_value do |server|
    server.non_bot_members.each do |member|
      member.roles.each do |role|
        ROLE_CACHE[member.id].push({guild: server.id, role: role.id})
      end
    end
  end
end

bot.member_update do |event| # member join will fire this, too
  cache = ROLE_CACHE[event.user.id]
  cache.clear
  event.roles.each do |role|
    cache.push({guild: event.server.id, role: role.id})
  end
end

bot.member_leave do |event|
  ROLE_CACHE.delete(event.user.id)
end

bot.reaction_add do |event|
  conf = REACTION_ROLES[REACTION_ROLE_KEY.new(event.server.id, event.channel.id, event.message.id, event.emoji.id || event.emoji.name)]
  if conf && event.user.is_a?(Discordrb::Member)
    unless ROLE_CACHE[event.user.id].include?({guild: event.server.id, role: conf[:role]})
      event.user.add_role conf[:role]
    end
  end
end

bot.reaction_remove do |event|
  conf = REACTION_ROLES[REACTION_ROLE_KEY.new(event.server.id, event.channel.id, event.message.id, event.emoji.id || event.emoji.name)]
  if conf && event.user.is_a?(Discordrb::Member) && conf[:remove]
    if ROLE_CACHE[event.user.id].include?({guild: event.server.id, role: conf[:role]})
      event.user.remove_role conf[:role]
    end
  end
end

bot.run
