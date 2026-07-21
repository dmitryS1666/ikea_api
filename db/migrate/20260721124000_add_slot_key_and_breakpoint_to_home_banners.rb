class AddSlotKeyAndBreakpointToHomeBanners < ActiveRecord::Migration[7.1]
  # Legacy integer mappings (unchanged in DB):
  # section: 0=main, 1=horizontal (was secondary), 2=advertising (new)
  # variant: 0=main_1500x516, 1=main_572x594, 2=horizontal_1500x256 (was secondary_*),
  #          3=horizontal_742x256, 4=main_960x516, 5=horizontal_960x256, 6=advertising_742x256
  VARIANT_TO_BREAKPOINT = {
    0 => 0, # main_1500x516 → desktop
    1 => 2, # main_572x594 → mobile
    2 => 0, # horizontal_1500x256 → desktop
    3 => 2, # horizontal_742x256 → mobile
    4 => 1, # main_960x516 → tablet
    5 => 1, # horizontal_960x256 → tablet
    6 => 3  # advertising_742x256 → all
  }.freeze

  def up
    add_column :home_banners, :slot_key, :string
    add_column :home_banners, :breakpoint, :integer

    # Backfill breakpoint from variant
    VARIANT_TO_BREAKPOINT.each do |variant, breakpoint|
      execute <<-SQL.squish
        UPDATE home_banners
        SET breakpoint = #{breakpoint}
        WHERE variant = #{variant} AND breakpoint IS NULL
      SQL
    end

    # Backfill slot_key by grouping existing responsive variants via section+position
    say_with_time "backfill home_banners.slot_key" do
      sections = connection.select_values("SELECT DISTINCT section FROM home_banners")
      sections.each do |section|
        positions = connection.select_values(
          "SELECT DISTINCT position FROM home_banners WHERE section = #{section.to_i} ORDER BY position"
        )
        positions.each do |position|
          prefix = case section.to_i
                   when 0 then "main"
                   when 1 then "horizontal"
                   when 2 then "advertising"
                   else "banner"
                   end
          slot_key = "#{prefix}-#{position}"
          execute <<-SQL.squish
            UPDATE home_banners
            SET slot_key = #{connection.quote(slot_key)}
            WHERE section = #{section.to_i}
              AND position = #{position.to_i}
              AND (slot_key IS NULL OR slot_key = '')
          SQL
        end
      end
    end

    change_column_null :home_banners, :slot_key, false
    change_column_null :home_banners, :breakpoint, false
    change_column_default :home_banners, :breakpoint, from: nil, to: 0

    add_index :home_banners, [:section, :slot_key, :breakpoint],
              name: "index_home_banners_on_section_slot_key_breakpoint"
    add_index :home_banners, [:section, :active, :slot_key, :breakpoint],
              unique: true,
              where: "active = TRUE",
              name: "index_home_banners_unique_active_slot_breakpoint"
  end

  def down
    remove_index :home_banners, name: "index_home_banners_unique_active_slot_breakpoint"
    remove_index :home_banners, name: "index_home_banners_on_section_slot_key_breakpoint"
    remove_column :home_banners, :breakpoint
    remove_column :home_banners, :slot_key
  end
end
