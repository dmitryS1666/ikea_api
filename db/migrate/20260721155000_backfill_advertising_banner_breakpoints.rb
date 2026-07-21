class BackfillAdvertisingBannerBreakpoints < ActiveRecord::Migration[7.1]
  # advertising_742x256 used to mean breakpoint "all" (3).
  # Now advertising has desktop/tablet/mobile like other sections;
  # existing 742×256 ads become mobile (2).
  def up
    execute <<-SQL.squish
      UPDATE home_banners
      SET breakpoint = 2
      WHERE section = 2
        AND variant = 6
        AND breakpoint = 3
    SQL
  end

  def down
    execute <<-SQL.squish
      UPDATE home_banners
      SET breakpoint = 3
      WHERE section = 2
        AND variant = 6
        AND breakpoint = 2
    SQL
  end
end
