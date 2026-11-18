# frozen_string_literal: true

module DiscourseMastodonMobileSso
  module NativePostAlerterExtension
    def create_notification(user, type, post, opts = {})
      notification = super
      if notification && Notification.like_types.include?(type)
        NativePushEvents.topic_reaction(notification, post, @default_opts.merge(opts))
      end
      notification
    end
  end

  module NativePushEvents
    def self.topic_reaction(notification, post, opts)
      return unless SiteSetting.mastodon_mobile_push_enabled
      actor_id = opts[:user_id] || post.user_id
      return if notification.read || actor_id == notification.user_id
      reaction_id =
        if notification.notification_type == Notification.types[:reaction] &&
             defined?(::DiscourseReactions::ReactionUser)
          ::DiscourseReactions::ReactionUser.where(post_id: post.id, user_id: actor_id).pick(:id)
        end
      like_id = opts[:post_action_id]
      if !reaction_id && !like_id
        like_id = PostAction.where(post_id: post.id, user_id: actor_id, post_action_type_id: PostActionType::LIKE_POST_ACTION_ID).pick(:id)
      end
      return unless reaction_id || like_id
      payload = {
        notification_type: notification.notification_type,
        topic_id: post.topic_id,
        post_id: post.id,
        post_number: post.post_number,
        actor_id: actor_id,
        native_event: "reaction",
        native_notification_id: notification.id,
        native_topic_reaction_id: reaction_id,
        native_post_action_id: like_id,
        native_event_id: reaction_id ? "topic-reaction-#{reaction_id}" : "topic-like-#{like_id}"
      }
      DB.after_commit { NativePush.enqueue(notification.user, payload) }
    end

    def self.chat_reply(message)
      return unless SiteSetting.mastodon_mobile_push_enabled
      original = message.in_reply_to || message.thread&.original_message
      return unless original && original.id != message.id
      recipient = original.user
      return unless chat_allowed?(recipient, message.user, message, "reply")
      membership = message.chat_channel.membership_for(recipient)
      # Core already handles channel-wide pushes and mentions (including group mentions).
      return if membership.notifications_always?
      mentions, = ::Chat::Notifier.new(message, Time.current).list_users_to_notify
      return if mentions.values.flatten.include?(recipient.id)
      notify_chat(recipient, message.user, message, "reply")
    end

    def self.chat_reaction(reaction)
      return unless SiteSetting.mastodon_mobile_push_enabled
      message = reaction.chat_message
      recipient = message.user
      return if !recipient || recipient.id == reaction.user_id
      return if recipient.user_option.like_notification_frequency ==
        UserOption.like_notification_frequency_type[:never]
      return if UserCommScreener.new(acting_user: reaction.user, target_user_ids: [recipient.id])
        .ignoring_or_muting_actor?(recipient.id)
      create_chat_reaction_notification(recipient, reaction, message)
      return unless chat_allowed?(recipient, reaction.user, message, "reaction")
      notify_chat(recipient, reaction.user, message, "reaction", reaction.id)
    end

    # Makes chat reactions appear in notifications.json like topic reactions do.
    def self.create_chat_reaction_notification(recipient, reaction, message)
      Notification.create!(
        user_id: recipient.id,
        notification_type: Notification.types[:reaction],
        data: {
          display_username: reaction.user.username,
          original_username: reaction.user.username,
          chat_channel_id: message.chat_channel_id,
          chat_channel_title: message.chat_channel.title(recipient),
          chat_message_id: message.id,
          chat_thread_id: message.thread_id,
          chat_reaction_id: reaction.id,
          emoji: reaction.emoji
        }.compact.to_json
      )
    end

    def self.chat_reaction_removed(reaction)
      Notification
        .where(notification_type: Notification.types[:reaction])
        .where("data::jsonb ->> 'chat_reaction_id' = ?", reaction.id.to_s)
        .destroy_all
    end

    def self.chat_allowed?(recipient, actor, message, event)
      return false if !recipient || recipient.id == actor.id
      return false unless PushDevice.exists?(user_id: recipient.id)
      payload = { notification_type: Notification.types[:chat_message], chat_message_id: message.id, native_event: event }.with_indifferent_access
      NativePush.allowed?(recipient, payload) && NativePush.target(recipient, payload) &&
        !UserCommScreener.new(acting_user: actor, target_user_ids: [recipient.id])
          .ignoring_or_muting_actor?(recipient.id)
    end

    def self.notify_chat(recipient, actor, message, event, reaction_id = nil)
      NativePush.enqueue(
        recipient,
        notification_type: Notification.types[:chat_message],
        chat_message_id: message.id,
        actor_id: actor.id,
        native_event: event,
        native_event_id: reaction_id ? "chat-reaction-#{reaction_id}" : nil,
        native_reaction_id: reaction_id
      )
    end
  end
end
