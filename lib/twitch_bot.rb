# frozen_string_literal: true

require 'securerandom'
require 'openssl'
require 'twitch-api'

# ==== Twitch Bot ====

class TwitchBot
  class EventSubSubscription
    attr_reader :id, :status, :type, :version, :cost, :condition, :transport
    def initialize(attributes = {})
      attributes.each do |key, value|
        instance_variable_set "@#{key}", value
      end
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

  def initialize(twitch_conf, http_conf, db, http)
    @conf = twitch_conf
    @http_conf = http_conf
    @db = db
    @http = http

    @bot_oauth_parms = {
      client_id: @conf[:client_id],
      client_secret: @conf[:client_secret]
    }
    @user_oauth_parms = @bot_oauth_parms.merge({
      token_type: :user,
      redirect_uri: uri("/oauth/callback")
    })

    @bot = TwitchClientPatched.new **@bot_oauth_parms

    init_eventsub
  end

  def init_eventsub
    @eventsub_secret = @db.twitch_eventsub_secret ||= SecureRandom.alphanumeric(16)
    @eventsub_subscriptions = []

    @http.twitch_webhook do |headers, body, server|
      pp body
    end
  end

  def uri(path)
    "https://#{@http_conf[:host]}#{@http_conf[:prefix]}#{path}"
  end

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

  def test
    pp @bot.get_eventsubs(status: "enabled").data
  end
end

=begin
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

=end


