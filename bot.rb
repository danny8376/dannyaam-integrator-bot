# frozen_string_literal: true

require 'set'
require 'discordrb'
require 'discordrb/webhooks'

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

CHANNEL_SYNC_KEY = Struct.new(:guild, :ch)
CHANNEL_SYNCED = Set.new
CHANNEL_WEBHOOK = {}
CHANNEL_WEBHOOK_IDS = []
CHANNEL_SYNC = {}
CHANNEL_SYNC.default_proc = proc { |h, k| h[k] = Set.new }
CHANNEL_SYNC_CONF.each do |sync_group|
  sync_group.map! do |v|
    ch = CHANNEL_SYNC_KEY.new(*v.values_at(:guild, :ch))
    CHANNEL_SYNCED.add(ch)
    ch
  end
  sync_group.each do |ch|
    sync_group.each do |tch|
      next if tch == ch
      CHANNEL_SYNC[ch].add(tch)
    end
  end
end

bot.ready do
  bot.servers.each_value do |server|
    server.non_bot_members.each do |member|
      member.roles.each do |role|
        ROLE_CACHE[member.id].push({guild: server.id, role: role.id})
      end
    end
    CHANNEL_SYNCED.each do |chkey|
      ch = bot.channel(chkey.ch, chkey.guild)
      webhook = ch.webhooks.find { |wh| wh.name == CHANNEL_SYNC_WEBHOOK_NAME } || ch.create_webhook(CHANNEL_SYNC_WEBHOOK_NAME)
      CHANNEL_WEBHOOK_IDS.push webhook.id
      CHANNEL_WEBHOOK[chkey] = Discordrb::Webhooks::Client.new(id: webhook.id, token: webhook.token)
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
  if event.server
    conf = REACTION_ROLES[REACTION_ROLE_KEY.new(event.server.id, event.channel.id, event.message.id, event.emoji.id || event.emoji.name)]
    if conf && event.user.is_a?(Discordrb::Member)
      unless ROLE_CACHE[event.user.id].include?({guild: event.server.id, role: conf[:role]})
        event.user.add_role conf[:role]
      end
    end
  end
end

bot.reaction_remove do |event|
  if event.server
    conf = REACTION_ROLES[REACTION_ROLE_KEY.new(event.server.id, event.channel.id, event.message.id, event.emoji.id || event.emoji.name)]
    if conf x&& event.user.is_a?(Discordrb::Member) && conf[:remove]
      if ROLE_CACHE[event.user.id].include?({guild: event.server.id, role: conf[:role]})
        event.user.remove_role conf[:role]
      end
    end
  end
end

bot.message do |event|
  if event.server
    chkey = CHANNEL_SYNC_KEY.new(event.server.id, event.channel.id)
    if chkey and not (event.message.webhook? and CHANNEL_WEBHOOK_IDS.include? event.message.webhook_id)
      # ignore file currently (avoid huge traffic)
      builder = Discordrb::Webhooks::Builder.new(
        content: event.message.content,
        username: event.user.username,
        avatar_url: event.user.avatar_url,
        tts: event.message.tts,
        embeds: event.message.embeds
      )
      CHANNEL_SYNC[chkey].each do |tchkey|
        CHANNEL_WEBHOOK[tchkey].execute builder
      end
    end
  end
end

bot.run
