# frozen_string_literal: true

require 'securerandom'
require 'openssl'
require 'date'
require 'twitch-api'
require 'faye/websocket'

# ==== Twitch Bot ====

class TwitchBot
  class Dummy
    def initialize(attributes = {})
      attributes.each do |key, value|
        instance_variable_set "@#{key}", value
        define_singleton_method key do
          instance_variable_get "@#{key}"
        end
      end
    end
  end
  class EventSubSubscription
    attr_reader :id, :status, :type, :version, :cost, :condition, :transport
    def initialize(attributes = {})
      attributes.each do |key, value|
        instance_variable_set "@#{key}", value
      end
    end
    def userid
      condition["broadcaster_user_id"].to_i
    end
  end
  
  class TwitchClientPatched < Twitch::Client
    def check_tokens
      @tokens = @oauth2_client.check_tokens(**@tokens, token_type: @token_type)
    end

    %w[delete].each do |http_method|
      define_method http_method do |resource, params|
        http_response = CONNECTION.public_send http_method, resource, params

        raise APIError.new(http_response.status, http_response.body) unless http_response.success?

        http_response
      end
    end

    def get_eventsubs(options = {})
        initialize_response EventSubSubscription, get('eventsub/subscriptions', options)
    end
  
    def delete_eventsub(options = {})
        delete('eventsub/subscriptions', options)
    end
  
    def register_eventsub(options = {})
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

    def pubsub(topics = [], &block)
      #require_access_token do
      token = @token_type == :user ? lambda { check_tokens[:access_token] } : nil
      PubSub.new(token: token, topics: topics, &block)
      #end
    end
  end

  class PubSub
    PUBSUB_URI = "wss://pubsub-edge.twitch.tv"

    def initialize(token: nil, topics: [], &block) # token string or lambda which gen token
      @token_lambda = token if token.is_a? Proc
      @token = token.is_a?(Proc) ? token.call : token
      @topics = topics
      raise "Too many topics" unless check_topics
      @callback = block
      @waiting_requests = {} # nonce => [type, time, wait, err_cb, data]
      @closing = false
      init_ws
      init_waiting_purge
    end

    def callback(&block)
      @callback = block
    end

    def regen_token
      raise "Outdated token" if @token_lambda.nil?
      @token = @token_lambda.call
    end

    def check_topics
      @topics.size <= 50
    end

    def ping_timer
      @ws_ping.cancel if @ws_ping
      @ws_ping = EventMachine::Timer.new(240+rand(-15..15)) do
        send("PING") { reconnect }

        ping_timer
      end
    end

    def init_waiting_purge
      @purge_timer = EventMachine::PeriodicTimer.new(60) do
        @waiting_requests.each do |nonce, (_, time, wait, err_cb, _)|
          wait = wait || 300 # default to 5 min
          if Time.now - time > wait # 5 min
            @waiting_requests.delete nonce
            err_cb.call :timeout if err_cb
          end
        end
      end
    end

    def init_ws(cnt = 0)
      # ws ping frame may be not required?
      @ws = Faye::WebSocket::Client.new(PUBSUB_URI, [], ping: 240)
      @ws.on(:open) { listen_topics }
      @ws.on(:message) { |evt| message evt }
      @ws.on(:close) do
        if @closing
          @ws_ping.cancel if @ws_ping
        else
          reconnect
        end
      end
      ping_timer
    end

    def reconnect(cnt = 0)
      delay = cnt >= 9 ? 600 : 2 ** cnt
      r = [delay/10, 15].min
      delay += rand(r..-r) if r != 0
      EM.add_timer(delay) do
        init_ws cnt
      end
    end

    def close
      @closing = true
      @purge_timer.cancel if @purge_timer
      @ws.close
    end

    def listen_topics(topics = nil)
      to_listen = if topics
                    new_topics = (@topics + topics).uniq
                    raise "Too many topics" if new_topics.size > 50
                    added = new_topics - @topics
                    @topics = new_topics
                    added
                  else
                    @topics
                  end
      send("LISTEN", {
          #auth_token: "",
          topics: to_listen
      }) do |type, error, req_type, req_data|
        # failed...
      end
    end

    def send(type, data = nil, &block)
      nonce = SecureRandom.alphanumeric(32)
      @waiting_requests[nonce] = [
        type,
        Time.now,
        type == "PING" ? 10 : nil,
        block,
        data
      ]
      json = {
        type: type,
        nonce: nonce
      }
      json[:data] = data if data
      @ws.send json.to_json
    end

    def message(evt)
      data = JSON.parse evt.data
      case data['type']
      when "RECONNECT"
        reconnect
      when "PONG"
        @waiting_requests.delete data['nonce']
      when "RESPONSE"
        error = data['error']
        if error
          (req_type, _, _, err_cb, req_data) = @waiting_requests[data['nonce']]
          err_cb.call :server, error, req_type, req_data
        end
        @waiting_requests.delete data['nonce']
      when "MESSAGE"
        @callback.call data['data'] if @callback
      end
    end
  end

  EventSubKey = Struct.new(:userid, :type)

  def initialize(twitch_conf, http_conf, sys)
    @conf = twitch_conf
    @http_conf = http_conf
    @db = sys.db
    @queue = sys.queue

    @log = Logger.new STDOUT, progname: "TwitchBot"
    @log.level = Logger.const_get($log_level.upcase)

    @bot_oauth_parms = {
      client_id: @conf[:client_id],
      client_secret: @conf[:client_secret]
    }
    @user_oauth_parms = @bot_oauth_parms.merge({
      token_type: :user,
      redirect_uri: uri("/oauth/callback")
    })

    @bot = TwitchClientPatched.new **@bot_oauth_parms
    @bot.access_token

    init_eventsub
    init_pubsub
    init_livenotify
    init_consumer
  end

  def init_eventsub
    @eventsub_secret = @db.twitch_eventsub_secret ||= SecureRandom.alphanumeric(16)
    @eventsub_subscriptions = []

    @subs = {}
    @conf[:userids].each do |userid, conf|
      if conf[:live_notify]
        %w(stream.online stream.offline).each do |type|
          @subs[EventSubKey.new(userid, type)] = nil # list required subs
        end
      end
    end
    @bot.get_eventsubs().data.each do |sub|
      case sub.status
      when "enabled"
        @subs[gen_eventsub_key(sub)] = sub # set existing subs
      when "webhook_callback_verification_pending"
        @subs[gen_eventsub_key(sub)] = sub # pending
      end
    end
    @subs.each do |k, v| # reg non-existing subs
      if v.nil?
        @log.info "Registering eventsub webhook (userid=#{k.userid}, type=#{k.type})"
        begin
          @bot.register_eventsub(
            user_id: k.userid,
            event_type: k.type,
            webhook: uri("/webhook"),
            secret: @eventsub_secret
          )
        rescue Exception => ex
          @log.error ex
        end
      end
    end
  end

  def init_pubsub
    # 5 topics max for each user => 10 user for each ws
    @common_pubsub = {} # id => pubsub
    @conf[:userids].each_slice(10) do |slice|
      topics = []
      slice.each do |userid, conf|
        topics.push "video-playback-by-id.#{userid}", "broadcast-settings-update.#{userid}" if conf[:live_notify]
      end
      begin
        @bot.pubsub(topics) { |data| process_pubsub data }
      rescue Exception => ex
        @bot.error ex
      end
    end
  end

  def init_livenotify
    @stream_status = {} # id => {}
    @stream_status.default_proc = proc do |h, k|
      h[k] = {
        live_status: {
          online: {
            online: nil,
            time: Time.at(0)
          },
          title: ""
        }
      }
    end
  end

  def init_consumer
    Thread.new do
      while task = @queue.consume(:twitch)
        case task[:type]
        when :webhook
          process_task_webhook **task[:data]
        end
      end
    end
  end

  def gen_eventsub_key(sub)
    EventSubKey.new sub.userid, sub.type
  end

  def uri(path)
    "https://#{@http_conf[:host]}#{@http_conf[:prefix]}/twitch#{path}"
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
    signature = OpenSSL::HMAC.hexdigest(digest, @eventsub_secret, hmac_message)
    req_sig == "sha256=#{signature}"
  end

  def process_task_webhook(headers:, body:, request:, server:, callback:)
    res = [400, {}, "Bad Request"]
    if verify_twitch_eventsub(server)
      case request.env['HTTP_TWITCH_EVENTSUB_MESSAGE_TYPE']
      when "webhook_callback_verification"
        @log.info "Recived webhook callback verification, return challenge"
        # return challenge to valid subscription
        res = body["challenge"]
      when "revocation"
        sub = EventSubSubscription.new body["subscription"]
        @log.info "Received webhook revocation (userid=#{sub.userid}, type=#{sub.type})"
        @subs.delete(gen_eventsub_key(sub))
        res = "OK"
      when "notification"
        sub = EventSubSubscription.new body["subscription"]
        event = body["event"]
7
        process_eventsub_notification sub, event

        res = "OK"
      end
    else
      res = [403, {}, "Bad Signature"]
    end
    callback.call res
  end

  def process_eventsub_notification(sub, event)
    case sub.type
    when "stream.online"
      update_online(
        event['broadcaster_user_id'].to_i,
        true,
        DateTime.parse(event['started_at']).to_time
      )
    when "stream.offline"
      update_online(
        event['broadcaster_user_id'].to_i,
        false,
        nil
      )
    end
  end

  def process_pubsub(data)
    topic, userid = data['topic'].split('.')
    userid = userid.to_i
    msg = JSON.parse data['message']
    case topic
    when "video-playback-by-id"
      case msg['type']
      when "stream-up"
        update_online(userid, true, Time.at(msg['server_time']))
      when "stream-down"
        update_online(userid, false, Time.at(msg['server_time']))
      end
    when "broadcast-settings-update"
      update_title(userid, msg['status'])
    end
  end

  def update_title(userid, title)
    @stream_status[userid][:live_status][:title] = title
  end

  def update_online(userid, online, time)
    return unless time
    old_status = @stream_status[userid][:live_status][:online]
    if online != old_status[:online] and time > old_status[:time]
      @stream_status[userid][:live_status][:online] = {
        online: online,
        time: time
      }
      live_notify userid
    end
  end

  def live_notify(userid)
    conf = @conf[:userids][userid]
    return unless conf[:live_notify]
    target = conf[:live_notify_target]
    # Discord
    @queue.push(:discord, {
      type: :twitch_live_notify,
      online: @stream_status[userid][:live_status][:online][:online],
      conf: target[:discord]
    }) if target[:discord]
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
    #pp @bot.get_users(id: ["25863177", "38652226"]).data
    #pp @bot.get_eventsubs.data
    #@bot.get_eventsubs.data.each do |sub|
    #  @bot.delete_eventsub id: sub.id
    #end
    #pp @bot.get_eventsubs(status: "enabled").data
  end
end

