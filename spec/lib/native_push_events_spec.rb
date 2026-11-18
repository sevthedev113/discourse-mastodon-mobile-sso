# frozen_string_literal: true

RSpec.describe DiscourseMastodonMobileSso::NativePushEvents do
  let(:recipient) { Fabricate(:user) }
  let(:actor) { Fabricate(:user) }
  let(:channel) { Fabricate(:category_channel, threading_enabled: true) }
  let(:parent) { Fabricate(:chat_message, chat_channel: channel, user: recipient) }
  let(:membership) { channel.membership_for(recipient) }
  let(:client) { instance_double(DiscourseMastodonMobileSso::FcmClient, send: nil) }

  before do
    SiteSetting.mastodon_mobile_push_enabled = true
    SiteSetting.push_notification_time_window_mins = 0
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    PostActionNotifier.enable
    allow(DiscourseMastodonMobileSso::FcmClient).to receive(:new).and_return(client)
    DiscourseMastodonMobileSso::PushDevice.create!(
      user: recipient,
      user_auth_token: UserAuthToken.generate!(user_id: recipient.id),
      token: "test-device-token-1234567890",
      platform: "ios"
    )
    channel.add(recipient)
    channel.add(actor)
    membership.update!(notification_level: :mention)
  end

  def reply(text = "A reply without a mention")
    result = Chat::CreateMessage.call(
      guardian: actor.guardian,
      params: { chat_channel_id: channel.id, in_reply_to_id: parent.id, message: "#{text} #{Fabricate.sequence(:native_reply)}" }
    )
    expect(result).to be_success
    result[:message_instance]
  end

  def queued_args
    Jobs::MastodonMobilePush.jobs.last.fetch("args").first.deep_symbolize_keys
  end

  it "pushes a direct chat reply with mentions-only membership and routes to its thread" do
    expect { reply }.to change { Jobs::MastodonMobilePush.jobs.size }.by(1)
    2.times { Jobs::MastodonMobilePush.new.execute(queued_args) }
    membership.update!(notification_level: :always)
    Jobs::MastodonMobilePush.new.execute(
      user_id: recipient.id,
      payload: queued_args[:payload].slice(:notification_type, :chat_message_id)
    )
    expect(client).to have_received(:send).once.with(
      a_kind_of(DiscourseMastodonMobileSso::PushDevice),
      title: "CAMFED",
      body: "#{actor.display_name} replied to your post in Groups.",
      data: hash_including("channel_id" => channel.id.to_s, "thread_message_id" => parent.id.to_s),
      event_key: a_kind_of(String)
    )
  end

  it "does not duplicate replies already covered by mentions or always-notify channels" do
    expect { reply("Hello @#{recipient.username}") }.not_to change { Jobs::MastodonMobilePush.jobs.size }
    membership.update!(notification_level: :always)
    expect { reply }.not_to change { Jobs::MastodonMobilePush.jobs.size }
  end

  it "suppresses self-replies, muted channels, never-notify channels and ignored actors" do
    parent
    expect { described_class.chat_reply(Fabricate(:chat_message, chat_channel: channel, user: recipient, in_reply_to: parent)) }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
    membership.update!(muted: true)
    expect { reply }.not_to change { Jobs::MastodonMobilePush.jobs.size }
    membership.update!(muted: false, notification_level: :never)
    expect { reply }.not_to change { Jobs::MastodonMobilePush.jobs.size }
    membership.update!(notification_level: :mention)
    Fabricate(:ignored_user, user: recipient, ignored_user: actor)
    expect { reply }.not_to change { Jobs::MastodonMobilePush.jobs.size }
  end

  it "pushes an added chat reaction once and cancels queued delivery when undone" do
    parent
    reactor = Chat::MessageReactor.new(actor, channel)
    expect { reactor.react!(message_id: parent.id, react_action: :add, emoji: "heart") }
      .to change { Jobs::MastodonMobilePush.jobs.size }.by(1)
    args = queued_args
    expect(args[:payload][:native_event]).to eq("reaction")
    expect { reactor.react!(message_id: parent.id, react_action: :add, emoji: "heart") }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
    expect { reactor.react!(message_id: parent.id, react_action: :remove, emoji: "heart") }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
    Jobs::MastodonMobilePush.new.execute(args)
    expect(client).not_to have_received(:send)
  end

  it "honours disabled reaction notifications" do
    recipient.user_option.update!(like_notification_frequency: UserOption.like_notification_frequency_type[:never])
    expect { Chat::MessageReactor.new(actor, channel).react!(message_id: parent.id, react_action: :add, emoji: "heart") }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
  end

  it "delivers separate reactions on the same message while deduplicating retries" do
    recipient.user_option.update!(push_notification_level: :chat_only, chat_enabled: true)
    reactor = Chat::MessageReactor.new(actor, channel)
    reactor.react!(message_id: parent.id, react_action: :add, emoji: "heart")
    first = queued_args
    reactor.react!(message_id: parent.id, react_action: :add, emoji: "+1")
    second = queued_args
    2.times do
      Jobs::MastodonMobilePush.new.execute(first)
      Jobs::MastodonMobilePush.new.execute(second)
    end
    expect(client).to have_received(:send).twice.with(
      a_kind_of(DiscourseMastodonMobileSso::PushDevice),
      title: "CAMFED",
      body: "#{actor.display_name} reacted to your post in Groups.",
      data: hash_including("message_id" => parent.id.to_s),
      event_key: a_kind_of(String)
    )
  end

  it "suppresses self-reactions and muted-thread interactions" do
    expect { Chat::MessageReactor.new(recipient, channel).react!(message_id: parent.id, react_action: :add, emoji: "heart") }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
    message = reply
    message.thread.user_chat_thread_memberships.find_by!(user: recipient).update!(notification_level: :muted)
    expect { reply }.not_to change { Jobs::MastodonMobilePush.jobs.size }
    expect { Chat::MessageReactor.new(actor, channel).react!(message_id: parent.id, react_action: :add, emoji: "heart") }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
  end

  it "forwards accepted topic likes but not disabled likes or removals" do
    post = Fabricate(:post, user: recipient)
    recipient.user_option.update!(like_notification_frequency: UserOption.like_notification_frequency_type[:always])
    expect { PostActionCreator.like(actor, post) }.to change { Jobs::MastodonMobilePush.jobs.size }.by(1)
    expect { PostActionDestroyer.new(actor, post, PostActionType::LIKE_POST_ACTION_ID).perform }
      .not_to change { Jobs::MastodonMobilePush.jobs.size }
    recipient.user_option.update!(like_notification_frequency: UserOption.like_notification_frequency_type[:never])
    expect { PostActionCreator.like(actor, post) }.not_to change { Jobs::MastodonMobilePush.jobs.size }
  end

  it "does not enqueue topic reactions from rolled-back transactions" do
    post = Fabricate(:post, user: recipient)
    recipient.user_option.update!(like_notification_frequency: UserOption.like_notification_frequency_type[:always])
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        PostActionCreator.like(actor, post)
        raise ActiveRecord::Rollback
      end
    end.not_to change { Jobs::MastodonMobilePush.jobs.size }
  end

  it "forwards topic emoji reactions without shadow-like duplicates or removal alerts" do
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_enabled_reactions = "heart|hugs"
    post = Fabricate(:post, user: recipient)
    recipient.user_option.update!(like_notification_frequency: UserOption.like_notification_frequency_type[:always])
    toggle = ->(user) { DiscourseReactions::ReactionManager.new(reaction_value: "hugs", user: user, post: post).toggle! }
    expect { toggle.call(actor) }.to change { Jobs::MastodonMobilePush.jobs.size }.by(1)
    first = queued_args
    other_actor = Fabricate(:user)
    expect { toggle.call(other_actor) }.to change { Jobs::MastodonMobilePush.jobs.size }.by(1)
    second = queued_args
    2.times do
      Jobs::MastodonMobilePush.new.execute(first)
      Jobs::MastodonMobilePush.new.execute(second)
    end
    [actor, other_actor].each do |reactor|
      expect(client).to have_received(:send).once.with(
        a_kind_of(DiscourseMastodonMobileSso::PushDevice),
        title: "CAMFED",
        body: "#{reactor.display_name} reacted to your post in Groups.",
        data: hash_including("topic_id" => post.topic_id.to_s, "post_number" => post.post_number.to_s),
        event_key: a_kind_of(String)
      )
    end
    expect { toggle.call(actor) }.not_to change { Jobs::MastodonMobilePush.jobs.size }
  end
end
