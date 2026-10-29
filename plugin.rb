# frozen_string_literal: true

# name: discourse-mastodon-mobile-sso
# about: Mobile SSO Authentication using Mastodon Access Token
# version: 0.2
# authors: Severus

after_initialize do
  module ::DiscourseMastodonMobileSso
    class Engine < ::Rails::Engine
      engine_name "discourse_mastodon_mobile_sso"
      isolate_namespace DiscourseMastodonMobileSso
    end

    class AuthController < ::ApplicationController
      # Keep a slow Mastodon server from tying up a Discourse worker.
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      # Raised when mastodon_sso_host is blank; answered with 503 instead of a generic 500.
      class NotConfigured < StandardError
      end

      # The app is not a browser: it sends a Mastodon bearer token, not a CSRF token.
      skip_before_action :check_xhr
      skip_before_action :verify_authenticity_token, only: [:authenticate]
      before_action :apply_rate_limit, only: [:authenticate]

      # POST /mobile_sso/auth/mastodon { access_token } signs the matching Discourse user in.
      def authenticate
        mastodon_token = params[:access_token]
        if mastodon_token.blank?
          return render json: { error: "Access token is required" }, status: :bad_request
        end

        # Mastodon is the source of truth for who the token belongs to.
        res =
          mastodon_get("/api/v1/accounts/verify_credentials", mastodon_token)
        unless res.is_a?(Net::HTTPSuccess)
          return render json: { error: "Invalid Mastodon token" }, status: :unauthorized
        end

        mastodon_user = JSON.parse(res.body)
        mastodon_id = mastodon_user["id"]
        # The Mastodon id is the permanent link; usernames can change.
        external_id = "mastodon:#{mastodon_id}"

        # One sign-in per Mastodon account at a time, so a double request can't create two users.
        user =
          DistributedMutex.synchronize(
            "mastodon-mobile-sso-#{external_id}",
            validity: 30
          ) { find_or_link_user(external_id, mastodon_user, res.body) }

        case user
        when :no_email
          return(
            render json: { error: "Unable to verify account" }, status: :forbidden
          )
        when :not_linkable
          return(
            render json: {
                     error: "Unable to sign in with this account"
                   },
                   status: :conflict
          )
        when :staff_not_allowed
          # The code lets the app show staff-specific guidance instead of the generic conflict text.
          return(
            render json: {
                     error: "Staff accounts need approval for mobile sign-in",
                     data: {
                       code: "staff_not_allowlisted"
                     }
                   },
                   status: :conflict
          )
        end

        # Sets the Discourse session cookie.
        log_on_user(user)
        # Chat joins a new user to its channels on their first "seen" event, which would otherwise fire after the app fetched an empty list.
        user.update_last_seen!

        render json: {
                 success: true,
                 user: {
                   id: user.id,
                   username: user.username,
                   name: user.name,
                   email: user.email
                 }
               }
      rescue NotConfigured => e
        Rails.logger.error("Mastodon mobile SSO: #{e.message}")
        render json: { error: "Mobile sign-in is unavailable" },
               status: :service_unavailable
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          "Mastodon mobile SSO: user creation failed: #{e.record.errors.full_messages.join(", ")}"
        )
        render json: { error: "Unable to create account" },
               status: :unprocessable_entity
      rescue => e
        Rails.logger.error(
          "Mastodon mobile SSO failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
        )
        render json: { error: "Authentication failed" }, status: :internal_server_error
      end

      private

      # Stops one IP from hammering the endpoint (and, through it, the Mastodon server).
      def apply_rate_limit
        RateLimiter.new(
          nil,
          "mastodon-sso-#{request.remote_ip}",
          20,
          1.minute
        ).performed!
      end

      # GET against the configured Mastodon server with the caller's bearer token.
      def mastodon_get(path, token)
        host = SiteSetting.mastodon_sso_host.to_s.strip.chomp("/")
        raise NotConfigured, "mastodon_sso_host is not configured" if host.blank?

        uri = URI("#{host}#{path}")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{token}"

        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        ) { |http| http.request(req) }
      end

      # Returns the Discourse user for this Mastodon account, or :no_email / :not_linkable / :staff_not_allowed.
      def find_or_link_user(external_id, mastodon_user, payload)
        # Returning users are matched by Mastodon id, never by email.
        sso_record = SingleSignOnRecord.find_by(external_id: external_id)
        return sso_record.user if sso_record

        # First sign-in: the email comes from Mastodon, never from the client.
        email = confirmed_email(mastodon_user)
        return :no_email if email.nil?

        existing_user = find_user_by_email(email)
        if existing_user && !linkable?(existing_user, external_id)
          return :not_linkable
        end
        if existing_user&.staff? && !staff_email_allowed?(email)
          return :staff_not_allowed
        end

        username = mastodon_user["username"]
        name = mastodon_user["display_name"].presence || username

        # User and link are written together so a failure never leaves a half-linked account.
        User.transaction do
          user = existing_user
          if user
            claim_unactivated_account!(user) unless user.active?
          else
            user =
              User.create!(
                email: email,
                username: UserNameSuggester.suggest(username),
                name: name,
                active: true,
                approved: true
              )
          end

          SingleSignOnRecord.create!(
            user_id: user.id,
            external_id: external_id,
            external_name: name,
            external_username: username,
            external_email: email,
            last_payload: payload
          )
          user
        end
      end

      # Mastodon confirmed this inbox, so activate the account and drop credentials whoever registered it first set.
      def claim_unactivated_account!(user)
        user.user_password&.destroy
        user.user_auth_tokens.destroy_all
        user.activate
      end

      # Mastodon only serves verify_credentials to confirmed accounts, so source.email is verified.
      def confirmed_email(mastodon_user)
        email = mastodon_user.dig("source", "email").to_s.strip.downcase
        email if EmailAddressValidator.valid_value?(email)
      end

      # Also matches addresses that differ only by +tags or dots when normalize_emails is on.
      def find_user_by_email(email)
        user = User.find_by_email(email)
        user ||=
          UserEmail.find_by_normalized(
            email
          )&.user if SiteSetting.normalize_emails
        user
      end

      # Email alone is not enough proof for staged or suspended users, or users already linked elsewhere.
      def linkable?(user, external_id)
        !user.staged? && !user.suspended? &&
          !SingleSignOnRecord
            .where(user_id: user.id)
            .where.not(external_id: external_id)
            .exists?
      end

      # Staff are linked only when an admin listed the exact Mastodon-confirmed email.
      def staff_email_allowed?(email)
        SiteSetting.mastodon_sso_staff_email_allowlist_map.map(&:downcase).include?(email)
      end
    end
  end

  DiscourseMastodonMobileSso::Engine.routes.draw do
    post "/auth/mastodon" => "auth#authenticate"
  end

  # Exposes the engine at /mobile_sso so the full path is POST /mobile_sso/auth/mastodon.
  Discourse::Application.routes.append do
    mount ::DiscourseMastodonMobileSso::Engine, at: "/mobile_sso"
  end
end
