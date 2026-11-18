# frozen_string_literal: true

RSpec.describe DiscourseMastodonMobileSso::FcmClient do
  let(:device) { instance_double(DiscourseMastodonMobileSso::PushDevice, token: "test-fcm-token") }
  let(:credentials) do
    {
      project_id: "test-project",
      client_email: "firebase@example.invalid",
      private_key: OpenSSL::PKey::RSA.new(2048).to_pem
    }
  end
  let(:fcm_url) { "https://fcm.googleapis.com/v1/projects/test-project/messages:send" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("DISCOURSE_FCM_CREDENTIALS").and_return("/test/firebase.json")
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with("/test/firebase.json").and_return(credentials.to_json)
    stub_request(:post, "https://oauth2.googleapis.com/token").to_return(
      status: 200, body: { access_token: "test-oauth-token", expires_in: 3600 }.to_json
    )
  end

  def send_push
    described_class.new.send(
      device,
      title: "CAMFED",
      body: "Someone reacted to your post in Groups.",
      data: { "source" => "discourse", "topic_id" => "7" },
      event_key: "event-key"
    )
  end

  it "authenticates with HTTP v1 and configures both mobile platforms" do
    stub_request(:post, fcm_url).with do |request|
      message = JSON.parse(request.body).fetch("message")
      expect(message["notification"]).to eq(
        "title" => "CAMFED",
        "body" => "Someone reacted to your post in Groups."
      )
      expect(request.headers["Authorization"]).to eq("Bearer test-oauth-token")
      expect(message.dig("android", "notification", "channel_id")).to eq("Patchwork")
      expect(message.dig("apns", "payload", "aps", "sound")).to eq("default")
      expect(message["data"]).to eq("source" => "discourse", "topic_id" => "7")
      true
    end.to_return(status: 200, body: "{}")
    send_push
  end

  it "raises a redacted error for retryable failures" do
    stub_request(:post, fcm_url).to_return(status: 503, body: '{"error":{"message":"test-fcm-token"}}')
    expect { send_push }.to raise_error(described_class::DeliveryError, "FCM delivery failed (HTTP 503)")
  end

  it "does not leak malformed response contents" do
    stub_request(:post, fcm_url).to_return(status: 503, body: "test-fcm-token")
    expect { send_push }.to raise_error(described_class::DeliveryError, "Invalid JSON in Firebase credentials or response")
  end

  it "removes only explicitly unregistered device credentials" do
    allow(device).to receive_messages(id: 1, user_id: 9, updated_at: Time.current)
    relation = double(delete_all: 1)
    allow(DiscourseMastodonMobileSso::PushDevice).to receive(:where).with(
      id: 1, user_id: 9, updated_at: device.updated_at
    ).and_return(relation)
    stub_request(:post, fcm_url).to_return(
      status: 404,
      body: { error: { details: [{ "@type" => "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode" => "UNREGISTERED" }] } }.to_json
    )
    send_push
    expect(DiscourseMastodonMobileSso::PushDevice).to have_received(:where).with(
      id: 1, user_id: 9, updated_at: device.updated_at
    )
  end
end
