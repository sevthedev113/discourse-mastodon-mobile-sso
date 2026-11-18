# frozen_string_literal: true

class CreateMastodonMobilePushDevices < ActiveRecord::Migration[7.0]
  def change
    create_table :mastodon_mobile_push_devices do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :user_auth_token, null: false, foreign_key: { on_delete: :cascade }
      t.string :token, null: false, limit: 2048
      t.string :platform, null: false, limit: 10
      t.timestamps
    end
    add_index :mastodon_mobile_push_devices, :token, unique: true
  end
end
