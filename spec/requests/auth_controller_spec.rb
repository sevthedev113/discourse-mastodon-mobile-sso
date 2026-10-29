# frozen_string_literal: true

RSpec.describe DiscourseMastodonMobileSso::AuthController do
  let(:host) { "https://mastodon.example.com" }
  let(:mastodon_id) { "109" }
  let(:external_id) { "mastodon:#{mastodon_id}" }
  let(:email) { "alice@example.com" }
  let(:verify_url) { "#{host}/api/v1/accounts/verify_credentials" }
  let(:credentials) do
    {
      id: mastodon_id,
      username: "alice",
      display_name: "Alice",
      source: {
        email: email
      }
    }
  end

  before do
    SiteSetting.mastodon_sso_host = host

    stub_request(:get, verify_url).with(
      headers: {
        "Authorization" => "Bearer user-token"
      }
    ).to_return(status: 200, body: credentials.to_json)
  end

  def authenticate(params = {})
    post "/mobile_sso/auth/mastodon.json",
         params: { access_token: "user-token" }.merge(params)
  end

  def expect_no_login_or_link
    expect(response.parsed_body["success"]).to be_blank
    expect(SingleSignOnRecord.where(external_id: external_id)).to be_empty
    expect(session[:current_user_id]).to be_blank
  end

  it "requires an access token" do
    post "/mobile_sso/auth/mastodon.json"
    expect(response.status).to eq(400)
  end

  it "rejects an invalid Mastodon token" do
    stub_request(:get, verify_url).to_return(status: 401, body: "{}")

    authenticate
    expect(response.status).to eq(401)
  end

  context "with a new user" do
    it "creates the user with the Mastodon-confirmed email and ignores the client email" do
      expect { authenticate(mail: "attacker@example.com") }.to change {
        User.count
      }.by(1)

      expect(response.status).to eq(200)
      user = User.find_by_email(email)
      expect(response.parsed_body).to eq(
        "success" => true,
        "user" => {
          "id" => user.id,
          "username" => user.username,
          "name" => "Alice",
          "email" => email
        }
      )
      expect(User.find_by_email("attacker@example.com")).to be_nil
      expect(user).to be_active

      record = SingleSignOnRecord.find_by(external_id: external_id)
      expect(record.user_id).to eq(user.id)
      expect(record.external_email).to eq(email)
      expect(record.external_username).to eq("alice")
      expect(record.last_payload).to eq(credentials.to_json)
      expect(session[:current_user_id]).to eq(user.id)
    end

  end

  context "with repeated sign-ins for a new account" do
    it "joins auto-join chat channels before responding" do
      SiteSetting.chat_enabled = true
      SiteSetting.chat_allowed_groups = Group::AUTO_GROUPS[:everyone]
      channel = Fabricate(:category_channel, auto_join_users: true)

      authenticate

      user = User.find_by_email(email)
      expect(
        Chat::UserChatChannelMembership.exists?(
          user_id: user.id,
          chat_channel_id: channel.id
        )
      ).to eq(true)
    end

    it "creates one user and one link, then reuses them" do
      expect { 2.times { authenticate } }.to change { User.count }.by(1)

      expect(SingleSignOnRecord.where(external_id: external_id).count).to eq(1)
      expect(response.status).to eq(200)
    end

    it "serializes sign-ins per Mastodon account" do
      # Other code (e.g. chat auto-join) takes its own mutexes, so only pin ours.
      allow(DistributedMutex).to receive(:synchronize).and_call_original
      expect(DistributedMutex).to receive(:synchronize).with(
        "mastodon-mobile-sso-#{external_id}",
        validity: 30
      ).and_call_original

      authenticate
      expect(response.status).to eq(200)
    end
  end

  context "with an already linked user" do
    fab!(:user)

    before do
      Fabricate(:single_sign_on_record, user: user, external_id: "mastodon:109")
    end

    it "logs in without needing an email from Mastodon" do
      stub_request(:get, verify_url).to_return(
        status: 200,
        body: credentials.except(:source).to_json
      )

      expect { authenticate }.not_to change { User.count }

      expect(response.status).to eq(200)
      expect(response.parsed_body["user"]["id"]).to eq(user.id)
      expect(session[:current_user_id]).to eq(user.id)
    end
  end

  context "with an existing Discourse user with the confirmed email" do
    fab!(:user) { Fabricate(:user, email: "alice@example.com", active: true) }

    it "links and logs in as that user" do
      expect { authenticate }.not_to change { User.count }

      expect(response.status).to eq(200)
      expect(response.parsed_body["user"]["id"]).to eq(user.id)

      record = SingleSignOnRecord.find_by(external_id: external_id)
      expect(record.user_id).to eq(user.id)
      expect(record.external_email).to eq(email)
      expect(session[:current_user_id]).to eq(user.id)
    end

    it "matches regardless of email case" do
      stub_request(:get, verify_url).to_return(
        status: 200,
        body: credentials.merge(source: { email: "Alice@Example.com" }).to_json
      )

      authenticate
      expect(response.parsed_body["user"]["id"]).to eq(user.id)
    end

    it "honours normalize_emails" do
      SiteSetting.normalize_emails = true
      user.user_emails.first.update!(email: "al.ice+forums@example.com")

      authenticate
      expect(response.parsed_body["user"]["id"]).to eq(user.id)
    end

    it "does not link when the user is already linked to a different Mastodon account" do
      Fabricate(:single_sign_on_record, user: user, external_id: "mastodon:999")

      authenticate
      expect(response.status).to eq(409)
      expect_no_login_or_link
    end

    it "does not link when the user is linked to another SSO provider" do
      Fabricate(:single_sign_on_record, user: user, external_id: "other-sso-id")

      authenticate
      expect(response.status).to eq(409)
      expect_no_login_or_link
    end

    it "does not link a suspended user" do
      user.update!(suspended_till: 1.year.from_now, suspended_at: Time.zone.now)

      authenticate
      expect(response.status).to eq(409)
      expect_no_login_or_link
    end
  end

  context "with an existing user that cannot be linked" do
    it "activates and links an unactivated user whose email Mastodon confirmed" do
      inactive = Fabricate(:inactive_user, email: email, password: "s3cret-passw0rd-old")
      old_token = UserAuthToken.generate!(user_id: inactive.id)

      expect { authenticate }.not_to change { User.count }

      expect(response.status).to eq(200)
      inactive.reload
      expect(inactive).to be_active
      expect(inactive.user_password).to be_nil
      expect(UserAuthToken.find_by(id: old_token.id)).to be_nil
      expect(
        SingleSignOnRecord.find_by(external_id: external_id).user_id
      ).to eq(inactive.id)
      expect(session[:current_user_id]).to eq(inactive.id)
    end

    it "rejects a staged user" do
      Fabricate(:staged, email: email)

      authenticate
      expect(response.status).to eq(409)
      expect(response.parsed_body["data"]).to be_nil
      expect_no_login_or_link
    end

    it "links an admin whose email is on the staff allowlist" do
      SiteSetting.mastodon_sso_staff_email_allowlist = "Other@example.com|ALICE@example.com"
      admin = Fabricate(:admin, email: email)

      authenticate
      expect(response.status).to eq(200)
      expect(response.parsed_body["user"]["id"]).to eq(admin.id)
      expect(session[:current_user_id]).to eq(admin.id)
    end

    it "rejects an admin whose email is not on the staff allowlist" do
      SiteSetting.mastodon_sso_staff_email_allowlist = "other@example.com"
      Fabricate(:admin, email: email)

      authenticate
      expect(response.status).to eq(409)
      expect(response.parsed_body["data"]["code"]).to eq("staff_not_allowlisted")
      expect_no_login_or_link
    end

    it "links an allowlisted moderator" do
      SiteSetting.mastodon_sso_staff_email_allowlist = email
      moderator = Fabricate(:moderator, email: email)

      authenticate
      expect(response.status).to eq(200)
      expect(response.parsed_body["user"]["id"]).to eq(moderator.id)
    end

    it "rejects an admin" do
      Fabricate(:admin, email: email)

      authenticate
      expect(response.status).to eq(409)
      expect(response.parsed_body["data"]["code"]).to eq("staff_not_allowlisted")
      expect_no_login_or_link
    end

    it "rejects a moderator" do
      Fabricate(:moderator, email: email)

      authenticate
      expect(response.status).to eq(409)
      expect(response.parsed_body["data"]["code"]).to eq("staff_not_allowlisted")
      expect_no_login_or_link
    end
  end

  context "when Mastodon does not provide a usable email" do
    it "returns 403 when source.email is missing" do
      stub_request(:get, verify_url).to_return(
        status: 200,
        body: credentials.except(:source).to_json
      )

      expect { authenticate }.not_to change { User.count }
      expect(response.status).to eq(403)
      expect_no_login_or_link
    end

    it "returns 403 when source.email is invalid" do
      stub_request(:get, verify_url).to_return(
        status: 200,
        body: credentials.merge(source: { email: "not-an-email" }).to_json
      )

      authenticate
      expect(response.status).to eq(403)
      expect_no_login_or_link
    end
  end

  context "when Mastodon fails" do
    it "returns 503 when the Mastodon host is not configured" do
      SiteSetting.mastodon_sso_host = ""

      authenticate
      expect(response.status).to eq(503)
      expect_no_login_or_link
    end

    it "returns 422 when the new user fails validation" do
      SiteSetting.blocked_email_domains = "example.com"

      expect { authenticate }.not_to change { User.count }
      expect(response.status).to eq(422)
      expect_no_login_or_link
    end

    it "returns a generic error and logs when verify_credentials fails unexpectedly" do
      stub_request(:get, verify_url).to_raise(
        StandardError.new("boom secret detail")
      )
      Rails.logger.expects(:error).with(regexp_matches(/boom secret detail/))

      authenticate
      expect(response.status).to eq(500)
      expect(response.parsed_body).to eq("error" => "Authentication failed")
    end
  end

  context "with rate limiting" do
    before { RateLimiter.enable }

    it "returns 429 after too many requests" do
      stub_request(:get, verify_url).to_return(status: 401, body: "{}")

      20.times do
        authenticate
        expect(response.status).to eq(401)
      end

      authenticate
      expect(response.status).to eq(429)
    end
  end
end
