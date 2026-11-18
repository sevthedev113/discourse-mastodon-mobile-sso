# frozen_string_literal: true

RSpec.describe Jobs::MastodonMobilePush do
  let(:user) { Fabricate(:user, last_seen_at: 1.day.ago) }
  let(:post) { Fabricate(:post) }
  let(:device) do
    DiscourseMastodonMobileSso::PushDevice.create!(
      user: user,
      user_auth_token: UserAuthToken.generate!(user_id: user.id),
      token: "test-device-token-1234567890",
      platform: "ios"
    )
  end
  let(:payload) do
    {
      notification_type: Notification.types[:mentioned],
      topic_id: post.topic_id,
      post_id: post.id,
      post_number: post.post_number,
      username: post.user.username,
      excerpt: "private content"
    }
  end
  let(:client) { instance_double(DiscourseMastodonMobileSso::FcmClient, send: nil) }

  before do
    SiteSetting.mastodon_mobile_push_enabled = true
    SiteSetting.push_notification_time_window_mins = 0
    device
    allow(DiscourseMastodonMobileSso::FcmClient).to receive(:new).and_return(client)
  end

  def deliver
    described_class.new.execute(user_id: user.id, payload: payload)
  end

  it "sends string-only routing data without excerpts and deduplicates successful deliveries" do
    2.times { deliver }
    expect(client).to have_received(:send).once.with(
      device,
      title: "CAMFED",
      body: "#{post.user.display_name} mentioned you in Groups.",
      data: {
        "source" => "discourse",
        "user_id" => user.id.to_s,
        "topic_id" => post.topic_id.to_s,
        "post_number" => post.post_number.to_s
      },
      event_key: a_kind_of(String)
    )
  end

  it "uses the named actor from the core payload rather than the post author" do
    SiteSetting.enable_names = true
    SiteSetting.prioritize_username_in_ux = false
    actor = Fabricate(:user, name: "Jane Doe")
    described_class.new.execute(
      user_id: user.id,
      payload: payload.merge(username: actor.username)
    )
    expect(client).to have_received(:send).with(
      device,
      title: "CAMFED",
      body: "Jane Doe mentioned you in Groups.",
      data: a_kind_of(Hash),
      event_key: a_kind_of(String)
    )
  end

  it "uses the reaction actor's username when their name is blank" do
    SiteSetting.enable_names = true
    SiteSetting.prioritize_username_in_ux = false
    actor = Fabricate(:user, name: nil)
    described_class.new.execute(
      user_id: user.id,
      payload: payload.merge(actor_id: actor.id, notification_type: Notification.types[:reaction])
    )
    expect(client).to have_received(:send).with(
      device,
      title: "CAMFED",
      body: "#{actor.username} reacted to your post in Groups.",
      data: a_kind_of(Hash),
      event_key: a_kind_of(String)
    )
  end

  it "keeps the generic actor fallback when no actor is available" do
    described_class.new.execute(user_id: user.id, payload: payload.except(:username))
    expect(client).to have_received(:send).with(
      device,
      title: "CAMFED",
      body: "Someone mentioned you in Groups.",
      data: a_kind_of(Hash),
      event_key: a_kind_of(String)
    )
  end

  it "does not send after access is removed" do
    post.topic.category.update!(read_restricted: true)
    deliver
    expect(client).not_to have_received(:send)
  end

  it "honours push filters and the recent-activity window" do
    allow(DiscourseMastodonMobileSso::NativePush).to receive(:allowed?).and_return(false)
    deliver
    expect(client).not_to have_received(:send)
    allow(DiscourseMastodonMobileSso::NativePush).to receive(:allowed?).and_call_original
    SiteSetting.push_notification_time_window_mins = 5
    user.update!(last_seen_at: Time.current)
    deliver
    expect(client).not_to have_received(:send)
  end

  it "retries failed deliveries rather than marking them successful" do
    allow(client).to receive(:send).and_raise(DiscourseMastodonMobileSso::FcmClient::DeliveryError)
    expect { deliver }.to raise_error(DiscourseMastodonMobileSso::FcmClient::DeliveryError)
    allow(client).to receive(:send).and_return(nil)
    deliver
    expect(client).to have_received(:send).twice
  end

  it "does not send for an expired or revoked session" do
    device.user_auth_token.update!(rotated_at: 2.years.ago)
    deliver
    expect(client).not_to have_received(:send)
  end

  it "includes the recipient's notification id so a push tap can mark it read" do
    notification = Fabricate(
      :notification,
      user: user,
      topic: post.topic,
      post_number: post.post_number,
      notification_type: Notification.types[:mentioned]
    )
    deliver
    expect(client).to have_received(:send) do |_device, **options|
      expect(options[:data]["notification_id"]).to eq(notification.id.to_s)
    end
  end

  it "queues from the core push event without requiring a browser push subscription" do
    expect { PostAlerter.push_notification(user, payload) }.to change {
      described_class.jobs.size
    }.by(1)
  end

  %i[actor_id string_actor_id username].each do |actor_source|
    context "when the system actor is identified by #{actor_source}" do
      let(:system_payload) do
        system = Discourse.system_user.reload
        system.update!(username: "renamed_system")
        identity =
          case actor_source
          when :actor_id
            { actor_id: system.id }
          when :string_actor_id
            { actor_id: system.id.to_s }
          when :username
            { username: system.username.upcase }
          end
        payload.merge(identity)
      end

      it "does not queue a mobile push" do
        expect { PostAlerter.push_notification(user, system_payload) }.not_to change {
          described_class.jobs.size
        }
      end

      it "does not deliver an already queued mobile push" do
        described_class.new.execute(user_id: user.id, payload: system_payload)
        expect(client).not_to have_received(:send)
      end
    end
  end

  it "still delivers human actions on a system-authored post" do
    actor = post.user
    post.update!(user: Discourse.system_user)
    described_class.new.execute(
      user_id: user.id,
      payload: payload.merge(actor_id: actor.id, notification_type: Notification.types[:reaction])
    )
    expect(client).to have_received(:send).with(
      device,
      title: "CAMFED",
      body: "#{actor.display_name} reacted to your post in Groups.",
      data: a_kind_of(Hash),
      event_key: a_kind_of(String)
    )
  end

  it "does not queue when DND or a core push filter suppresses the event" do
    allow(user).to receive(:do_not_disturb?).and_return(true)
    expect { PostAlerter.push_notification(user, payload) }.not_to change {
      described_class.jobs.size
    }
    allow(user).to receive(:do_not_disturb?).and_return(false)
    SiteSetting.chat_enabled = true
    user.user_option.update!(push_notification_level: :chat_only, chat_enabled: true)
    expect { PostAlerter.push_notification(user, payload) }.not_to change {
      described_class.jobs.size
    }
  end

  it "sends chat targets only to authorised, following, unmuted members" do
    SiteSetting.chat_enabled = true
    SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
    channel = Fabricate(:category_channel)
    membership = Fabricate(:user_chat_channel_membership, user: user, chat_channel: channel, following: true)
    message = Fabricate(:chat_message, chat_channel: channel)
    chat_payload = { chat_message_id: message.id, notification_type: Notification.types[:chat_mention] }.with_indifferent_access
    expect(DiscourseMastodonMobileSso::NativePush.target(user, chat_payload)).to include(channel_id: channel.id.to_s, message_id: message.id.to_s)
    membership.update!(muted: true)
    expect(DiscourseMastodonMobileSso::NativePush.target(user, chat_payload)).to be_nil
  end

  it "uses event-specific bodies without exposing excerpts or the Discourse site title" do
    SiteSetting.title = "Discourse"
    {
      Notification.types[:replied] => "#{post.user.display_name} replied to your post in Groups.",
      Notification.types[:reaction] => "#{post.user.display_name} reacted to your post in Groups.",
      Notification.types[:posted] => "You have new activity in Groups."
    }.each do |type, body|
      described_class.new.execute(user_id: user.id, payload: payload.merge(notification_type: type))
      expect(client).to have_received(:send).with(device, title: "CAMFED", body: body, data: a_kind_of(Hash), event_key: a_kind_of(String))
    end
  end
end
