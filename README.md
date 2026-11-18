# CAMFED Discourse Mobile SSO & Push

Custom Discourse plugin for Mastodon mobile SSO and Firebase push notifications.
Keep this plugin in its own Git repository.

## Backend setup

1. Add this repository's URL to your Discourse deployment's plugin list.
   For a standard Docker deployment, add this under the existing
   `hooks.after_code` commands in `containers/app.yml`:
   ```yaml
   - git clone <PLUGIN_REPO_URL>
   ```
   Use the existing `/var/www/discourse/plugins` working directory. If this plugin
   is already installed, update its repository entry instead of adding a duplicate.
2. Complete the Firebase setup below.
3. Rebuild Discourse using your normal deployment process, including database
   migrations. Restart both web and Sidekiq workers.
4. In Discourse Admin settings, enable `mastodon_mobile_push_enabled`.

## Firebase credentials

1. Reuse our existing Firebase Admin SDK service-account JSON file.
2. Store the key outside the repository and mount it into the Discourse runtime.
   Only the runtime user should be able to read it.
3. Set this environment variable for **both web and Sidekiq**, using the path
   inside the runtime:
   ```env
   DISCOURSE_FCM_CREDENTIALS=/secure/firebase-service-account.json
   ```

## Quick check

On a physical device with the integrated mobile build, sign in, allow
notifications, and trigger a mention, reply, or reaction from another account.
System-account pushes are excluded; web notifications remain unchanged.

For immediate testing, temporarily set `push_notification_time_window_mins` to
`0`, then restore the production value.




## Mastodon profile sync

Mastodon is the source of truth for linked accounts. The profile is synced on
every sign-in (`POST /mobile_sso/auth/mastodon`) and on demand
(`POST /mobile_sso/sync/profile`, requires a Discourse session and a Mastodon
token for the same linked account).

| Field  | Behavior |
| ------ | -------- |
| Name   | Mastodon display name, falling back to the username. |
| Email  | Updated to Mastodon's confirmed email. If another account already uses it, the change is skipped and logged. |
| Bio    | Mastodon note converted to plain text (entities decoded, paragraph and line breaks kept). An empty note clears the bio. |
| Avatar | Downloaded only when the Mastodon avatar URL changed since the last sync. |

Username is not synced; accounts are linked by Mastodon id, so username changes
on either side don't break the link.

Behavior notes:

- Each field is synced independently, so one failure (logged as a warning)
  doesn't block the others or the sign-in.
- The sync snapshot is saved before the avatar job is enqueued, so a failure
  can't cause repeated downloads. It stores only `id`, `username`,
  `display_name` and `avatar`, not the email.
- Syncs run under a per-user lock, so a sign-in and an explicit sync can't
  enqueue duplicate avatar downloads.
- For linked users, Discourse blocks editing name, email and avatar (Guardian)
  and ignores bio, location and website updates (`UserUpdater`), and the
  matching profile controls are hidden.