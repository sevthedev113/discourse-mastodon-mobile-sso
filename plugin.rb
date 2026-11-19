# frozen_string_literal: true

# name: discourse-mastodon-mobile-sso
# about: Mobile SSO Authentication using Mastodon Access Token
# version: 0.3
# authors: Severus

after_initialize do
  # ---------------------------------------------------------------------------
  # Mastodon is the source of truth for profile data.
  # Prevent users from editing these fields directly inside Discourse.
  # ---------------------------------------------------------------------------

  module ::DiscourseMastodonMobileSso
    # These Guardian checks drive both profile UI permissions and server-side guards.
    module GuardianExtension
      def mastodon_sso_linked?(target_user)
        # Bind the pattern so its % wildcard is not parsed as a format token.
        @mastodon_sso_linked ||= {}
        @mastodon_sso_linked.fetch(target_user.id) do
          @mastodon_sso_linked[target_user.id] = SingleSignOnRecord
            .where(user_id: target_user.id)
            .where("external_id LIKE ?", "mastodon:%")
            .exists?
        end
      end

      def can_edit_email?(target_user)
        return false if mastodon_sso_linked?(target_user)
        super
      end

      def can_edit_name?(target_user)
        return false if mastodon_sso_linked?(target_user)
        super
      end

      def can_edit_avatar?(target_user)
        return false if mastodon_sso_linked?(target_user)
        super
      end
    end

    module UserUpdaterExtension
      def update(attributes = {})
        if Guardian.new(@actor).mastodon_sso_linked?(@user)
          # UserUpdater has no Guardian check for these fields, so discard them here as
          # well as hiding their controls in the serializer.
          attributes =
            attributes.except(
              :bio_raw,
              "bio_raw",
              :location,
              "location",
              :website,
              "website"
            )
        end
        super(attributes)
      end
    end

    module UserSerializerExtension
      # These flags hide Mastodon-owned controls in the profile and account settings UI.
      def can_change_bio
        super && !scope.mastodon_sso_linked?(object)
      end

      def can_change_location
        super && !scope.mastodon_sso_linked?(object)
      end

      def can_change_website
        super && !scope.mastodon_sso_linked?(object)
      end
    end

    class Engine < ::Rails::Engine
      engine_name "discourse_mastodon_mobile_sso"
      isolate_namespace DiscourseMastodonMobileSso
    end

    Guardian.prepend(GuardianExtension)
    UserUpdater.prepend(UserUpdaterExtension)
    UserSerializer.prepend(UserSerializerExtension)

    # -------------------------------------------------------------------------
    # Shared helpers used by both AuthController and SyncController.
    # -------------------------------------------------------------------------
    module MastodonApi
      # Raised when mastodon_sso_host is blank; answered with 503 instead of a generic 500.
      class NotConfigured < StandardError
      end

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      # GET against the configured Mastodon server with the caller's bearer token.
      def mastodon_get(path, token)
        host = SiteSetting.mastodon_sso_host.to_s.strip.chomp("/")
        if host.blank?
          raise NotConfigured, "mastodon_sso_host is not configured"
        end

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
    end

    # -------------------------------------------------------------------------
    # Profile sync: copies Mastodon fields into the Discourse user record.
    # Called on every login and on explicit sync requests from the app.
    # Fields synced: display_name, avatar, bio (note field), email.
    # -------------------------------------------------------------------------
    module ProfileSync
      include MastodonApi

      # mastodon_user – parsed JSON from /api/v1/accounts/verify_credentials
      def sync_profile(user, mastodon_user)
        # Serialise per user so a login and an explicit sync can't both enqueue the avatar job.
        DistributedMutex.synchronize(
          "mastodon-profile-sync-#{user.id}",
          validity: 30
        ) { apply_profile_sync(user, mastodon_user) }
      rescue => e
        # Sync failure must not block login.
        Rails.logger.warn(
          "Mastodon profile sync failed for user #{user.id}: #{e.class}: #{e.message}"
        )
      end

      private

      def apply_profile_sync(user, mastodon_user)
        # Keep the LIKE wildcard bound; interpolating this pattern alongside a hash
        # condition raised a format error and stopped sync before any fields were applied.
        sso =
          SingleSignOnRecord
            .where(user_id: user.id)
            .where("external_id LIKE ?", "mastodon:%")
            .first

        # Each field is isolated so one failure doesn't stop the others.
        new_name =
          mastodon_user["display_name"].presence || mastodon_user["username"]
        safe_sync(user, "name") { sync_name(user, new_name) }
        safe_sync(user, "email") { sync_email(user, sso, mastodon_user) }
        safe_sync(user, "bio") { sync_bio(user, mastodon_user) }

        avatar_url = mastodon_user["avatar"].to_s.strip
        # last_payload is the last successful Mastodon snapshot; avoid re-downloading when
        # the URL is unchanged. The first-link payload omits avatar so it downloads once.
        previous_avatar_url =
          begin
            JSON.parse(sso&.last_payload.to_s)["avatar"].to_s.strip
          rescue JSON::ParserError
            ""
          end

        # Save the snapshot before enqueueing so a later failure can't cause repeated downloads.
        sso&.update_columns(
          external_name: new_name,
          external_username: mastodon_user["username"],
          last_payload:
            mastodon_user.slice("id", "username", "display_name", "avatar").to_json
        )

        if avatar_url.present? && avatar_url != previous_avatar_url
          safe_sync(user, "avatar") do
            Jobs.enqueue(
              :download_avatar_from_url,
              url: avatar_url,
              user_id: user.id,
              override_gravatar: true
            )
          end
        end
      end

      def safe_sync(user, field)
        yield
      rescue => e
        Rails.logger.warn(
          "Mastodon profile sync: #{field} update failed for user #{user.id}: #{e.class}: #{e.message}"
        )
      end

      def sync_name(user, new_name)
        user.update!(name: new_name) if new_name.present? && user.name != new_name
      end

      # Only update when Mastodon returns a confirmed email that differs.
      def sync_email(user, sso, mastodon_user)
        new_email = mastodon_user.dig("source", "email").to_s.strip.downcase
        return unless EmailAddressValidator.valid_value?(new_email)
        return if user.email.to_s.downcase == new_email

        # Fails validation if another account owns this address; that is logged by safe_sync.
        user.primary_email.update!(email: new_email)
        sso&.update_columns(external_email: new_email)
      end

      def sync_bio(user, mastodon_user)
        new_bio = html_to_text(mastodon_user["note"].to_s)
        profile = user.user_profile
        return if new_bio == profile.bio_raw.to_s.strip

        profile.bio_raw = new_bio
        profile.save!(validate: false)
      end

      # Converts Mastodon's HTML note to plain text, keeping paragraph/line breaks.
      def html_to_text(html)
        html = html.gsub(%r{<br\s*/?>}i, "\n").gsub(%r{</p>\s*<p[^>]*>}i, "\n\n")
        text = Nokogiri::HTML.fragment(html).text
        text.gsub(/[ \t]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
      end
    end

    # -------------------------------------------------------------------------
    # POST /mobile_sso/auth/mastodon — signs the matching Discourse user in.
    # -------------------------------------------------------------------------
    class AuthController < ::ApplicationController
      include MastodonApi
      include ProfileSync

      # The app is not a browser: it sends a Mastodon bearer token, not a CSRF token.
      skip_before_action :check_xhr
      skip_before_action :verify_authenticity_token, only: [:authenticate]
      before_action :apply_rate_limit, only: [:authenticate]

      def authenticate
        mastodon_token = params[:access_token]
        if mastodon_token.blank?
          return(
            render json: {
                     error: "Access token is required"
                   },
                   status: :bad_request
          )
        end

        # Mastodon is the source of truth for who the token belongs to.
        res =
          mastodon_get("/api/v1/accounts/verify_credentials", mastodon_token)
        unless res.is_a?(Net::HTTPSuccess)
          return(
            render json: {
                     error: "Invalid Mastodon token"
                   },
                   status: :unauthorized
          )
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
            render json: {
                     error: "Unable to verify account"
                   },
                   status: :forbidden
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

        # Sync Mastodon profile into Discourse on every login.
        sync_profile(user, mastodon_user)

        # Sets the Discourse session cookie.
        log_on_user(user)
        # Chat joins a new user to its channels on their first "seen" event,
        # which would otherwise fire after the app fetched an empty list.
        user.update_last_seen!

        render json: {
                 success: true,
                 user: {
                   id: user.id,
                   username: user.username,
                   name: user.name,
                   email: user.email,
                   admin: user.admin?,
                   moderator: user.moderator?
                 }
               }
      rescue MastodonApi::NotConfigured => e
        Rails.logger.error("Mastodon mobile SSO: #{e.message}")
        render json: {
                 error: "Mobile sign-in is unavailable"
               },
               status: :service_unavailable
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn(
          "Mastodon mobile SSO: user creation failed: #{e.record.errors.full_messages.join(", ")}"
        )
        render json: {
                 error: "Unable to create account"
               },
               status: :unprocessable_entity
      rescue => e
        Rails.logger.error(
          "Mastodon mobile SSO failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
        )
        render json: {
                 error: "Authentication failed"
               },
               status: :internal_server_error
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

      # Returns the Discourse user for this Mastodon account, or a symbol error key.
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
            # Keep initial sync eligible for the first avatar download.
            last_payload: JSON.parse(payload).except("avatar").to_json
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
        SiteSetting
          .mastodon_sso_staff_email_allowlist_map
          .map(&:downcase)
          .include?(email)
      end
    end

    # -------------------------------------------------------------------------
    # POST /mobile_sso/sync/profile — explicit profile sync triggered by the app
    # (e.g. when the user taps "Edit Profile"). Requires an active Discourse
    # session; the Mastodon token is re-verified so stale data is never used.
    # -------------------------------------------------------------------------
    class SyncController < ::ApplicationController
      include MastodonApi
      include ProfileSync

      skip_before_action :check_xhr
      skip_before_action :verify_authenticity_token, only: [:profile]
      before_action :apply_rate_limit, only: [:profile]
      before_action :ensure_logged_in, only: [:profile]

      def profile
        mastodon_token = params[:access_token]
        if mastodon_token.blank?
          return(
            render json: {
                     error: "Access token is required"
                   },
                   status: :bad_request
          )
        end

        # Only linked users can trigger a sync.
        sso_record =
          SingleSignOnRecord
            .where(user_id: current_user.id)
            .where("external_id LIKE ?", "mastodon:%")
            .first
        unless sso_record
          return(
            render json: {
                     error: "Account is not linked to Mastodon"
                   },
                   status: :forbidden
          )
        end

        # Re-verify the token so we always pull fresh data and confirm the token
        # still belongs to this user.
        res =
          mastodon_get("/api/v1/accounts/verify_credentials", mastodon_token)
        unless res.is_a?(Net::HTTPSuccess)
          return(
            render json: {
                     error: "Invalid Mastodon token"
                   },
                   status: :unauthorized
          )
        end

        mastodon_user = JSON.parse(res.body)

        # Guard against a token that belongs to a different Mastodon account.
        expected_id = sso_record.external_id.delete_prefix("mastodon:")
        if mastodon_user["id"].to_s != expected_id.to_s
          return(
            render json: {
                     error: "Token does not match the linked Mastodon account"
                   },
                   status: :forbidden
          )
        end

        sync_profile(current_user, mastodon_user)

        current_user.reload
        render json: {
                 success: true,
                 user: {
                   id: current_user.id,
                   username: current_user.username,
                   name: current_user.name,
                   email: current_user.email
                 }
               }
      rescue MastodonApi::NotConfigured => e
        Rails.logger.error("Mastodon profile sync: #{e.message}")
        render json: {
                 error: "Sync is unavailable"
               },
               status: :service_unavailable
      rescue => e
        Rails.logger.error(
          "Mastodon profile sync failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
        )
        render json: {
                 error: "Profile sync failed"
               },
               status: :internal_server_error
      end

      private

      def apply_rate_limit
        RateLimiter.new(
          nil,
          "mastodon-sync-#{current_user&.id}",
          10,
          1.minute
        ).performed!
      end
    end
  end

  require_relative "lib/native_push"
  require_relative "lib/native_push_events"
  PostAlerter.prepend(DiscourseMastodonMobileSso::NativePostAlerterExtension)

  on(:chat_message_created) do |message, *_args|
    DiscourseMastodonMobileSso::NativePushEvents.chat_reply(message)
  end

  if defined?(::Chat::MessageReaction)
    add_model_callback(::Chat::MessageReaction, :after_commit, on: :create) do
      DiscourseMastodonMobileSso::NativePushEvents.chat_reaction(self)
    end
    add_model_callback(::Chat::MessageReaction, :after_commit, on: :destroy) do
      DiscourseMastodonMobileSso::NativePushEvents.chat_reaction_removed(self)
    end
  end

  on(:push_notification) do |user, payload|
    DiscourseMastodonMobileSso::NativePush.enqueue(user, payload)
  end

  DiscourseMastodonMobileSso::Engine.routes.draw do
    post "/auth/mastodon" => "auth#authenticate"
    post "/sync/profile" => "sync#profile"
    post "/push/device" => "push_devices#register"
    delete "/push/device" => "push_devices#destroy"
  end

  # Exposes the engine at /mobile_sso so the full paths are:
  #   POST /mobile_sso/auth/mastodon
  #   POST /mobile_sso/sync/profile
  Discourse::Application.routes.append do
    mount ::DiscourseMastodonMobileSso::Engine, at: "/mobile_sso"
  end
end
