# frozen_string_literal: true

require 'set'
require 'yaml'
require 'securerandom'
require 'openssl'
require 'twitch-api'
require 'sinatra/base'
require 'discordrb'
require 'discordrb/webhooks'

require 'pp'

require "./CONFIG"

# ==== DB? ====

class CrudeDB
  def initialize(dbf)
    @dbf = dbf
    @db = File.exist?(@dbf) ? YAML.load(File.read(@dbf)) : {}
  end
  def [](key)
    @db[key]
  end
  def []=(key,val)
    @db[key] = val
    save
  end
  def save
    File.write(@dbf, @db.to_yaml)
  end
end

DB = CrudeDB.new DB_FILENAME


# ==== Webhook Server ====

class WebhookServer < Sinatra::Base
  @@twitch_callbacks = []

  configure do
    set :server, 'thin'
    set :bind, HTTP_BACKEND_BIND
    set :port, HTTP_BACKEND_PORT
  end

  post "#{HTTP_BACKEND_PREFIX}/webhook" do
    body = JSON.parse(request.body.read) rescue {}

    @@twitch_callbacks.each do |cb|
      request.body.rewind
      res = cb.call headers, body, self
      return res if res
    end

    [404, "no backend"]
  end

  def self.twitch_webhook(once=true, &block)
    @@twitch_callbacks.push(lambda { |*args|
      res = block.call *args
      @@twitch_callbacks.delete block if once and res
      res
    })
  end
end


# ==== Twitch API ====

class EventSubSubscription
  def initialize(attributes = {})
    pp attributes
  end
end

class TwitchClientPatched < Twitch::Client
  def get_eventsubs(options = {})
      initialize_response EventSubSubscription, get('eventsub/subscriptions', options)
  end

  def eventsub(options = {})
    eventsub_options = {
      type: options[:event_type],
      version: "1",
      condition: {
        broadcaster_user_id: options[:user_id]
      },
      transport: {
        method: "webhook",
        callback: options[:webhook],
        secret: options[:secret]
      }
    }
    require_access_token do
      initialize_response EventSubSubscription, post('eventsub/subscriptions', eventsub_options)
    end
  end
end

TWITCH_OAUTH_PARM = {
  client_id: TWITCH_CLIENT_ID,
  client_secret: TWITCH_CLIENT_SECRET,
  token_type: :user,
  redirect_uri: TWITCH_CALLBACK
}

=begin
  TWITCH_CLIENT = Twitch::Client.new(**TWITCH_OAUTH_PARM.merge((DB[:twitch_token] || {}).slice(:access_token, :refresh_token)))
rescue TwitchOAuth2::Error => error
  puts "NO ACCESS TOKEN, PLEASE GO => #{error.metadata[:link]} <= FOR TOKEN"
  puts "Type the code you got above: "
  client = TwitchOAuth2::Client.new(**TWITCH_OAUTH_PARM.slice(:client_id, :client_secret, :redirect_uri, :scope))
  code = gets.chomp
  DB[:twitch_token] = client.token(token_type: :user, code: code)
  retry
=end

TWITCH_APP_CLIENT = TwitchClientPatched.new(**TWITCH_OAUTH_PARM.slice(:client_id, :client_secret))

#pp TWITCH_APP_CLIENT.get_users(login: "danny8376")

DB[:twitch_eventsub_secret] ||= SecureRandom.alphanumeric(16)

def verify_twitch_eventsub(server)
  request = server.request
  body = request.body.read
  request.body.rewind # rewind for real usage
  msg_id = request.env['HTTP_TWITCH_EVENTSUB_MESSAGE_ID']
  timestamp = request.env['HTTP_TWITCH_EVENTSUB_MESSAGE_TIMESTAMP']
  req_sig = request.env['HTTP_TWITCH_EVENTSUB_MESSAGE_SIGNATURE']
  hmac_message = "#{msg_id}#{timestamp}#{body}"
  digest = OpenSSL::Digest.new('sha256')
  signature = OpenSSL::HMAC.hexdigest(digest, DB[:twitch_eventsub_secret], hmac_message)
  req_sig == "sha256=#{signature}"
end

secret = DB[:twitch_eventsub_secret]

puts "SECRET: #{secret}"

DB[:twitch_eventsub_subscriptions] ||= []

if false # DB[:twitch_eventsub_subscriptions].size <= 1

#=begin
res = TWITCH_APP_CLIENT.eventsub(
  event_type: "stream.offline",
  #user_id: "25863177", # ME:danny8376
  user_id: "38652226", # ME:danny0609
  webhook: "https://test.botsub.saru.moe/dannyaam-integrator-bot/webhook",
  secret: secret
)
pp res
#=end

status = res.body["data"][0]["status"] rescue "webhook_callback_verification_pending"

if status == "webhook_callback_verification_pending"

  WebhookServer.twitch_webhook do |headers, body, server|
    if verify_twitch_eventsub(server)
      DB[:twitch_eventsub_subscriptions].push body["subscription"]
      DB.save
      pp DB[:twitch_eventsub_subscriptions]
      body["challenge"] # return challenge to valid subscription
    end
  end

end

else

pp DB[:twitch_eventsub_subscriptions]

end


WebhookServer.twitch_webhook do |headers, body, server|
  pp body
end

#pp TWITCH_CLIENT.get_clips(id: "GleamingCulturedAntelopeDxCat")


# ==== DC Bot ====

bot = Discordrb::Bot.new token: BOT_TOKEN

puts "This bot's invite URL is #{bot.invite_url}."
puts 'Click on it to invite it to your server.'

ROLE_CACHE = {} # userid => [{guild, role}, ...]
ROLE_CACHE.default_proc = proc { |h, k| h[k] = [] }

existing_role_list = []
REACTION_ROLE_KEY = Struct.new(:guild, :ch, :msg, :emote)
REACTION_ROLES = {}
REACTION_ROLES_CONF.each do |val|
  if existing_role_list.include? val[:role]
    raise "Config Error: One role should only be managed by one reaction"
    exit
  end
  existing_role_list.push(val[:role])
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

bot.ready do
  # init role cache
  role_to_users = {}
  role_to_users.default_proc = proc { |h, k| h[k] = [] }
  bot.servers.each_value do |server|
    server.non_bot_members.each do |member|
      member.roles.each do |role|
        ROLE_CACHE[member.id].push({guild: server.id, role: role.id})
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
  REACTION_ROLES.each do |key, val|
    init_role_keys[key.guild][key.ch][key.msg].add({emote: key.emote, role: val})
  end
  init_role_keys.each do |guild_id, gval|
    role_update_list = {} # user => { add: [role, ...], remove: [role, ...] }
    role_update_list.default_proc = proc { |h, k| h[k] = { add: [], remove: [] } }
    guild = bot.servers[guild_id]
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
  # init/cache webhook for channel syncing
  CHANNEL_SYNCED.each do |chkey|
    ch = bot.channel(chkey.ch, chkey.guild)
    webhook = ch.webhooks.find { |wh| wh.name == CHANNEL_SYNC_WEBHOOK_NAME } || ch.create_webhook(CHANNEL_SYNC_WEBHOOK_NAME)
    CHANNEL_WEBHOOK_IDS.push webhook.id
    CHANNEL_WEBHOOK[chkey] = Discordrb::Webhooks::Client.new(id: webhook.id, token: webhook.token)
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
    if conf && event.user.is_a?(Discordrb::Member) && conf[:remove]
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

#bot.run
WebhookServer.run!
