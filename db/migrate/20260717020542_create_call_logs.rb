class CreateCallLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :call_logs do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.references :customer, null: true, foreign_key: true
      t.references :order, null: true, foreign_key: true
      t.string :external_call_id, null: false
      t.string :phone_number, null: false
      t.text :transcript
      t.string :recording_url
      t.string :status, null: false, default: "in_progress"
      t.datetime :started_at
      t.datetime :ended_at

      t.timestamps
    end

    add_index :call_logs, :external_call_id, unique: true
  end
end
