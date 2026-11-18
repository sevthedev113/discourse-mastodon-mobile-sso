# frozen_string_literal: true

RSpec.describe DiscourseMastodonMobileSso::PushDevicesController do
  let(:user) { Fabricate(:user) }
  let(:token) { "test-device-token-1234567890" }
  let(:path) { "/mobile_sso/push/device.json" }
  let(:params) { { token: token, platform: "ios", user_id: user.id } }

  it "requires a session" do
    post path, params: params
    expect(response.status).to eq(403)
  end

  it "registers idempotently and associates the active session" do
    sign_in(user)
    2.times { post path, params: params }
    expect(response.status).to eq(200)
    device = DiscourseMastodonMobileSso::PushDevice.find_by!(token: token)
    expect(DiscourseMastodonMobileSso::PushDevice.count).to eq(1)
    expect(device.user_id).to eq(user.id)
    expect(device.user_auth_token.user_id).to eq(user.id)
  end

  it "rejects a stale account id and malformed tokens" do
    sign_in(user)
    post path, params: params.merge(user_id: user.id + 1)
    expect(response.status).to eq(403)
    post path, params: params.merge(token: "invalid")
    expect(response.status).to eq(400)
    expect(DiscourseMastodonMobileSso::PushDevice.count).to eq(0)
  end

  it "moves the device to a newly authenticated account and prevents old-owner revocation" do
    sign_in(user)
    post path, params: params
    other = Fabricate(:user)
    sign_in(other)
    post path, params: params.merge(user_id: other.id)
    expect(response.status).to eq(200)
    sign_in(user)
    delete path, params: { token: token }
    expect(DiscourseMastodonMobileSso::PushDevice.find_by!(token: token).user_id).to eq(other.id)
    sign_in(other)
    delete path, params: { token: token }
    expect(DiscourseMastodonMobileSso::PushDevice.count).to eq(0)
  end

  it "revokes devices when their Discourse session is destroyed" do
    sign_in(user)
    post path, params: params
    device = DiscourseMastodonMobileSso::PushDevice.find_by!(token: token)
    device.user_auth_token.destroy!
    expect(DiscourseMastodonMobileSso::PushDevice.exists?(id: device.id)).to eq(false)
  end
end
