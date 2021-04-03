# frozen_string_literal: true

require 'set'
require 'discordrb'
require 'discordrb/webhooks'

# ==== DC Bot ====

class DiscordBot

  ReactionRoleKey = Struct.new(:guild, :ch, :msg, :emote)
  ChannelSyncKey = Struct.new(:guild, :ch)

  # dirty hack for discordrb bug -3-
  class SpNilClass
    def nil?
      true
    end
    def to_s
      "100"
    end
  end
  SpNil = SpNilClass.new

  def initialize(conf)
    @conf = conf
    @bot = Discordrb::Bot.new token: @conf[:token]

    puts "This bot's invite URL is #{@bot.invite_url}."
    puts 'Click on it to invite it to your server.'

    init_reaction_roles
    init_channel_sync
  end

  def init_reaction_roles
    # prepare data
    @role_cache = {} # userid => [{guild, role}, ...]
    @role_cache.default_proc = proc { |h, k| h[k] = [] }
    
    existing_role_list = []
    
    @reaction_roles = {}
    @conf[:reaction_roles].each do |val|
      if existing_role_list.include? val[:role]
        raise "Config Error: One role should only be managed by one reaction"
        exit
      end
      existing_role_list.push(val[:role])
      @reaction_roles[ReactionRoleKey.new(*val.values_at(:guild, :ch, :msg, :emote))] = val.slice(:guild, :role, :remove)
    end

    # setup bot
    @bot.ready do
      # init role cache
      role_to_users = {}
      role_to_users.default_proc = proc { |h, k| h[k] = [] }
      @bot.servers.each_value do |server|
        server.non_bot_members.each do |member|
          member.roles.each do |role|
            @role_cache[member.id].push({guild: server.id, role: role.id})
            role_to_users[role.id].push member.id
          end
        end
      end
      # start-up reaction role syncing
      init_role_keys = {} # server => { ch => { msg => [ {emote, role} , ...] } }
      init_role_keys.default_proc = proc do |h, k|
        new_hash = {}
        new_hash.default_proc = proc do |h, k|
          new_hash = {}
          new_hash.default_proc = proc { |h, k| h[k] = Set.new }
          h[k] = new_hash
        end
        h[k] = new_hash
      end
      @reaction_roles.each do |key, val|
        init_role_keys[key.guild][key.ch][key.msg].add({emote: key.emote, role: val})
      end
      init_role_keys.each do |guild_id, gval|
        role_update_list = {} # user => { add: [role, ...], remove: [role, ...] }
        role_update_list.default_proc = proc { |h, k| h[k] = { add: [], remove: [] } }
        guild = @bot.servers[guild_id]
        guild.channels.each do |ch|
          next unless gval.keys.include? ch.id
          gval[ch.id].each do |msg_id, emotes|
            msg = ch.message(msg_id)
            if msg
              emotes.each do |val|
                emote, role_val = val.values_at(:emote, :role)
                role_id, remove = role_val.values_at(:role, :remove)
                reaction = msg.reactions.find { |reaction| (reaction.id || reaction.name) == emote }
                if reaction
                  new_role_users = msg.reacted_with(reaction.to_s, limit: SpNil).map { |member| member.id }
                  old_role_users = role_to_users[role_id]
                  (new_role_users - old_role_users).each do |member_id|
                    role_update_list[member_id][:add].push role_id
                  end
                  if remove
                    (old_role_users - new_role_users).each do |member_id|
                      role_update_list[member_id][:remove].push role_id
                    end
                  end
                elsif remove # reaction cleared => remove all existing role member if remove is set
                  role_to_users[role_id].each do |member_id|
                    role_update_list[member_id][:remove].push role_id
                  end
                end
              end
            end
          end
        end
        role_update_list.each do |member_id, updates|
          # member should already be cached (by init role cache above), thus should be no performance problem to discord api
          guild.member(member_id).modify_roles(*updates.values_at(:add, :remove))
        end
      end
    end

    @bot.member_update do |event| # member join will fire this, too
      cache = @role_cache[event.user.id]
      cache.clear
      event.roles.each do |role|
        cache.push({guild: event.server.id, role: role.id})
      end
    end
    
    @bot.member_leave do |event|
      @role_cache.delete(event.user.id)
    end
    
    @bot.reaction_add do |event|
      if event.server
        conf = @reaction_roles[ReactionRoleKey.new(event.server.id, event.channel.id, event.message.id, event.emoji.id || event.emoji.name)]
        if conf && event.user.is_a?(Discordrb::Member)
          unless @role_cache[event.user.id].include?({guild: event.server.id, role: conf[:role]})
            event.user.add_role conf[:role]
          end
        end
      end
    end
    
    @bot.reaction_remove do |event|
      if event.server
        conf = @reaction_roles[ReactionRoleKey.new(event.server.id, event.channel.id, event.message.id, event.emoji.id || event.emoji.name)]
        if conf && event.user.is_a?(Discordrb::Member) && conf[:remove]
          if @role_cache[event.user.id].include?({guild: event.server.id, role: conf[:role]})
            event.user.remove_role conf[:role]
          end
        end
      end
    end
  end

  def init_channel_sync
    # prepare data
    @channel_synced = Set.new
    @channel_webhook = {}
    @channel_webhook_ids = []
    @channel_sync = {}
    @channel_sync.default_proc = proc { |h, k| h[k] = Set.new }
    @conf[:channel_sync][:sync_list].each do |sync_group|
      sync_group.map! do |v|
        ch = ChannelSyncKey.new(*v.values_at(:guild, :ch))
        @channel_synced.add(ch)
        ch
      end
      sync_group.each do |ch|
        sync_group.each do |tch|
          next if tch == ch
          @channel_sync[ch].add(tch)
        end
      end
    end

    # init bot
    @bot.ready do
      # init/cache webhook for channel syncing
      @channel_synced.each do |chkey|
        ch = @bot.channel(chkey.ch, chkey.guild)
        webhook = ch.webhooks.find { |wh| wh.name == @conf[:channel_sync][:webhook_name] } || ch.create_webhook(@conf[:channel_sync][:webhook_name])
        @channel_webhook_ids.push webhook.id
        @channel_webhook[chkey] = Discordrb::Webhooks::Client.new(id: webhook.id, token: webhook.token)
      end
    end

    @bot.message do |event|
      if event.server
        chkey = ChannelSyncKey.new(event.server.id, event.channel.id)
        if chkey and not (event.message.webhook? and @channel_webhook_ids.include? event.message.webhook_id)
          # ignore file currently (avoid huge traffic)
          builder = Discordrb::Webhooks::Builder.new(
            content: event.message.content,
            username: event.user.username,
            avatar_url: event.user.avatar_url,
            tts: event.message.tts,
            embeds: event.message.embeds
          )
          @channel_sync[chkey].each do |tchkey|
            @channel_webhook[tchkey].execute builder
          end
        end
      end
    end
  end

  def run
    @bot.run
  end
end

