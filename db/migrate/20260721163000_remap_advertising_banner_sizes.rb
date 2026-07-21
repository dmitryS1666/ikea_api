class RemapAdvertisingBannerSizes < ActiveRecord::Migration[7.1]
  # Advertising sizes:
  #   desktop → 742×256 (variant 6), two banners in a row on frontend
  #   tablet  → 960×256 (variant 8)
  #   mobile  → 960×256 (variant 9, advertising_mobile_960x256)
  def up
    # Existing 742×256 ads were previously tagged as mobile/all → desktop
    execute <<-SQL.squish
      UPDATE home_banners
      SET breakpoint = 0
      WHERE section = 2 AND variant = 6
    SQL

    # Existing 960×256 stay tablet
    execute <<-SQL.squish
      UPDATE home_banners
      SET breakpoint = 1
      WHERE section = 2 AND variant = 8
    SQL

    # Legacy 1500×256 desktop ads: keep desktop breakpoint (admin should re-upload as 742)
    execute <<-SQL.squish
      UPDATE home_banners
      SET breakpoint = 0
      WHERE section = 2 AND variant = 7
    SQL
  end

  def down
    # Best-effort reverse: 742 → mobile (previous convention)
    execute <<-SQL.squish
      UPDATE home_banners
      SET breakpoint = 2
      WHERE section = 2 AND variant = 6
    SQL
  end
end
