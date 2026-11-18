# frozen_string_literal: true

require "net/http"
require "openssl"
require "base64"
require "digest"

module DiscourseMastodonMobileSso
  class PushDevice < ActiveRecord::Base
    self.table_name = "mastodon_mobile_push_devices"
    belongs_to :user
    belongs_to :user_auth_token
    # Hide device credentials in model inspection.
    self.filter_attributes += [:token]
    validates :token, presence: true, length: { maximum: 2048 }
    validates :platform, inclusion: { in: %w[android ios] }
  end

  class PushDevicesController < ::ApplicationController
    requires_login

    def register
      token = params.require(:token)
      platform = params.require(:platform)
      unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9_:.-]{20,2048}\z/) &&
               %w[android ios].include?(platform)
        raise Discourse::InvalidParameters
      end
      # A late request from an old account must not register against a replaced cookie.
      raise Discourse::InvalidAccess unless params[:user_id].to_s == current_user.id.to_s
      session_token = request.env[Auth::DefaultCurrentUserProvider::USER_TOKEN_KEY]
      raise Discourse::InvalidAccess unless session_token&.user_id == current_user.id
      RateLimiter.new(current_user, "mobile-push-device", 30, 1.minute).performed!
      DistributedMutex.synchronize("mobile-push-device-#{Digest::SHA256.hexdigest(token)}") do
        device = PushDevice.find_or_initialize_by(token: token)
        device.update!(user: current_user, user_auth_token: session_token, platform: platform)
      end
      render json: success_json
    end

    def destroy
      token = params.require(:token)
      raise Discourse::InvalidParameters unless token.is_a?(String)
      PushDevice.where(user_id: current_user.id, token: token).delete_all
      render json: success_json
    end
  end

  module NativePush
    def self.notification_id(user, payload)
      notifications = Notification.where(user_id: user.id, read: false)
      if payload[:native_notification_id]
        notifications = notifications.where(notification_type: payload[:notification_type])
        id = notifications.where(id: payload[:native_notification_id]).pick(:id)
        return id if id
      end
      if payload[:chat_message_id]
        notifications = notifications.where("data::jsonb ->> 'chat_message_id' = ?", payload[:chat_message_id].to_s)
      elsif payload[:topic_id] && payload[:post_number]
        notifications = notifications.where(topic_id: payload[:topic_id], post_number: payload[:post_number])
      else
        return
      end
      notifications.order(id: :desc).pick(:id)
    end

    def self.actor(payload)
      if payload[:actor_id]
        User.find_by(id: payload[:actor_id])
      elsif payload[:username].present?
        User.find_by_username(payload[:username])
      end
    end

    def self.allowed?(user, payload)
      user.active? && !user.suspended? && !user.do_not_disturb? &&
        actor(payload)&.id != Discourse::SYSTEM_USER_ID &&
        DiscoursePluginRegistry.push_notification_filters.all? { |filter| filter.call(user, payload) }
    end

    def self.enqueue(user, payload)
      return unless SiteSetting.mastodon_mobile_push_enabled
      return unless PushDevice.exists?(user_id: user.id) && allowed?(user, payload)
      window = SiteSetting.push_notification_time_window_mins
      delay =
        if window > 0 && user.seen_since?(window.minutes.ago)
          [window.minutes - (Time.current - user.last_seen_at), 0].max
        else
          0
        end
      Jobs.enqueue_in(delay, :mastodon_mobile_push, user_id: user.id, payload: payload)
    end

    # Recheck access after queuing: membership or category visibility may have changed.
    def self.target(user, payload)
      if payload[:native_notification_id]
        return unless notification_id(user, payload)
      end
      if payload[:actor_id]
        return if payload[:actor_id] == user.id
        actor = User.find_by(id: payload[:actor_id])
        return unless actor
        return if UserCommScreener.new(acting_user: actor, target_user_ids: [user.id])
          .ignoring_or_muting_actor?(user.id)
      end
      if payload[:native_event] == "reaction"
        return if user.user_option.like_notification_frequency ==
          UserOption.like_notification_frequency_type[:never]
      end
      if payload[:chat_message_id]
        return unless defined?(::Chat::Message)
        return unless SiteSetting.chat_enabled && user.user_option.chat_enabled
        message = ::Chat::Message.find_by(id: payload[:chat_message_id])
        return unless message && message.deleted_at.nil?
        channel = message.chat_channel
        membership = channel.user_chat_channel_memberships.find_by(user_id: user.id)
        return unless membership&.following? && !membership.muted? && !membership.notifications_never?
        if payload[:notification_type] == Notification.types[:chat_message] && !payload[:native_event]
          return unless membership.notifications_always?
        end
        return if message.thread_id && ::Chat::UserChatThreadMembership.exists?(
          user_id: user.id, thread_id: message.thread_id, notification_level: ::Chat::NotificationLevels.all[:muted]
        )
        if payload[:native_reaction_id]
          return unless ::Chat::MessageReaction.exists?(
            id: payload[:native_reaction_id], chat_message_id: message.id, user_id: payload[:actor_id]
          )
        end
        return unless user.guardian.can_join_chat_channel?(channel)
        data = { channel_id: channel.id.to_s, message_id: message.id.to_s }
        if message.thread_id
          data[:thread_id] = message.thread_id.to_s
          data[:thread_message_id] = message.thread.original_message_id.to_s
        end
        data
      elsif payload[:topic_id]
        topic = Topic.find_by(id: payload[:topic_id])
        return unless topic && user.guardian.can_see?(topic)
        return if payload[:native_event] && TopicUser.exists?(
          user_id: user.id, topic_id: topic.id, notification_level: TopicUser.notification_levels[:muted]
        )
        post = Post.find_by(id: payload[:post_id]) if payload[:post_id]
        return if payload[:post_id] && (!post || !user.guardian.can_see?(post))
        if payload[:native_topic_reaction_id]
          return unless defined?(::DiscourseReactions::ReactionUser) &&
            ::DiscourseReactions::ReactionUser.exists?(id: payload[:native_topic_reaction_id], post_id: post.id, user_id: payload[:actor_id])
        end
        if payload[:native_post_action_id]
          return unless PostAction.exists?(id: payload[:native_post_action_id], post_id: post.id, user_id: payload[:actor_id], post_action_type_id: PostActionType::LIKE_POST_ACTION_ID, deleted_at: nil)
        end
        { topic_id: topic.id.to_s, post_number: payload[:post_number].to_s }
      end
    end

    def self.body(payload)
      type = payload[:notification_type]
      event =
        if payload[:native_event] == "reaction" || Notification.like_types.include?(type)
          "reaction"
        elsif payload[:native_event] == "reply" ||
              [Notification.types[:replied], Notification.types[:chat_watched_thread]].include?(type)
          "reply"
        elsif [Notification.types[:mentioned], Notification.types[:group_mentioned], Notification.types[:chat_mention]].include?(type)
          "mention"
        elsif type == Notification.types[:chat_message] &&
              (message = ::Chat::Message.find_by(id: payload[:chat_message_id])) &&
              (message.in_reply_to_id || (message.thread_id && message.thread.original_message_id != message.id))
          "reply"
        else
          "activity"
        end
      return I18n.t("mastodon_mobile_push.activity") if event == "activity"

      actor_name = actor(payload)&.display_name.presence || payload[:username].presence ||
        I18n.t("mastodon_mobile_push.unknown_actor")
      I18n.t("mastodon_mobile_push.#{event}", actor: actor_name)
    end
  end

  class FcmClient
    class DeliveryError < StandardError
    end

    OAUTH_URL = URI("https://oauth2.googleapis.com/token")
    SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

    def initialize
      # Credentials stay outside the database, repository and admin/client settings.
      @credentials = parse_json(File.read(ENV.fetch("DISCOURSE_FCM_CREDENTIALS")))
      @project = @credentials.fetch("project_id")
      raise DeliveryError, "Invalid Firebase project id" unless @project.match?(/\A[a-z0-9-]+\z/)
    end

    def send(device, title:, body:, data:, event_key:)
      uri = URI("https://fcm.googleapis.com/v1/projects/#{@project}/messages:send")
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request["Authorization"] = "Bearer #{access_token}"
      # Keep private message excerpts off lock screens. Fetch content after authentication.
      request.body = {
        message: {
          token: device.token,
          notification: { title: title, body: body },
          data: data,
          android: {
            priority: "high",
            collapse_key: event_key,
            notification: { channel_id: "Patchwork", tag: event_key }
          },
          apns: {
            headers: { "apns-collapse-id" => event_key },
            payload: { aps: { sound: "default" } }
          }
        }
      }.to_json
      response = perform(uri, request)
      return if response.code.to_i == 200
      error = parse_json(response.body).fetch("error", {})
      unregistered =
        Array(error["details"]).any? do |detail|
          detail["@type"] == "type.googleapis.com/google.firebase.fcm.v1.FcmError" &&
            detail["errorCode"] == "UNREGISTERED"
        end
      if unregistered
        # Do not delete a token reassigned to another user while this request was in flight.
        PushDevice.where(id: device.id, user_id: device.user_id, updated_at: device.updated_at).delete_all
        return
      end
      if response.code.to_i == 401
        Discourse.redis.del(oauth_cache_key)
      end
      # FCM responses can contain tokens; never include the response body in errors.
      raise DeliveryError, "FCM delivery failed (HTTP #{response.code})"
    end

    private

    def oauth_cache_key
      "mastodon-mobile-fcm-oauth:#{Digest::SHA256.hexdigest(@credentials.fetch("client_email") + @credentials.fetch("private_key"))}"
    end

    def access_token
      cached = Discourse.redis.get(oauth_cache_key)
      return cached if cached
      now = Time.now.to_i
      encode = ->(value) { Base64.urlsafe_encode64(value.to_json, padding: false) }
      header = encode.call(alg: "RS256", typ: "JWT")
      claims = encode.call(
        iss: @credentials.fetch("client_email"),
        scope: SCOPE,
        aud: OAUTH_URL.to_s,
        iat: now,
        exp: now + 3600
      )
      unsigned = "#{header}.#{claims}"
      signature = OpenSSL::PKey::RSA.new(@credentials.fetch("private_key")).sign("SHA256", unsigned)
      assertion = "#{unsigned}.#{Base64.urlsafe_encode64(signature, padding: false)}"
      request = Net::HTTP::Post.new(OAUTH_URL)
      request.set_form_data(
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: assertion
      )
      response = perform(OAUTH_URL, request)
      unless response.code.to_i == 200
        raise DeliveryError, "FCM OAuth failed (HTTP #{response.code})"
      end
      result = parse_json(response.body)
      token = result.fetch("access_token")
      Discourse.redis.setex(oauth_cache_key, [result.fetch("expires_in").to_i - 60, 1].max, token)
      token
    end

    def perform(uri, request)
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: true,
        open_timeout: 5,
        read_timeout: 10
      ) { |http| http.request(request) }
    end

    def parse_json(value)
      JSON.parse(value)
    rescue JSON::ParserError
      raise DeliveryError, "Invalid JSON in Firebase credentials or response", cause: nil
    end
  end
end

module Jobs
  class MastodonMobilePush < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.mastodon_mobile_push_enabled
      user = User.find_by(id: args[:user_id])
      payload = args[:payload].with_indifferent_access
      return unless user && DiscourseMastodonMobileSso::NativePush.allowed?(user, payload)
      window = SiteSetting.push_notification_time_window_mins
      return if window > 0 && user.seen_since?(window.minutes.ago)
      target = DiscourseMastodonMobileSso::NativePush.target(user, payload)
      return unless target

      data = { source: "discourse", user_id: user.id.to_s }.merge(target).stringify_keys
      if notification_id = DiscourseMastodonMobileSso::NativePush.notification_id(user, payload)
        data["notification_id"] = notification_id.to_s
      end
      event = [user.id, payload[:notification_type], target]
      event << payload[:native_event_id] if payload[:native_event_id]
      event_key = Digest::SHA256.hexdigest(event.to_json)
      title = "CAMFED"
      client = nil
      delivery_error = nil
      devices =
        DiscourseMastodonMobileSso::PushDevice
          .joins(:user_auth_token)
          .merge(UserAuthToken.unexpired)
          .where(user_id: user.id)
      devices.find_each do |device|
        key = "mastodon-mobile-push:#{event_key}:#{device.id}"
        DistributedMutex.synchronize("mobile-push-device-#{Digest::SHA256.hexdigest(device.token)}", validity: 60) do
          next if Discourse.redis.get(key)
          # Registration and account transfer use the same lock.
          next unless devices.exists?(id: device.id, token: device.token)
          client ||= DiscourseMastodonMobileSso::FcmClient.new
          begin
            I18n.with_locale(user.effective_locale) do
              client.send(device, title: title, body: DiscourseMastodonMobileSso::NativePush.body(payload), data: data, event_key: event_key)
            end
            Discourse.redis.setex(key, 1.day.to_i, "1")
          rescue DiscourseMastodonMobileSso::FcmClient::DeliveryError,
                 Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError => error
            # Attempt every device; retry only failed deliveries on the next job run.
            delivery_error ||= error
          end
        end
      end
      raise delivery_error if delivery_error
    end
  end
end
