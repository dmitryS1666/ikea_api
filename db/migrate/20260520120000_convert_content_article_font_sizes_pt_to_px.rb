class ConvertContentArticleFontSizesPtToPx < ActiveRecord::Migration[7.1]
  FONT_SIZE_PT_PATTERN = /font-size:\s*(\d+(?:\.\d+)?)\s*pt/i

  def up
    ContentArticle.reset_column_information
    ContentArticle.find_each do |article|
      updated_body_blocks = convert_blocks_font_sizes(article.body_blocks)
      updated_tile_blocks = convert_blocks_font_sizes(article.tile_blocks)

      next if updated_body_blocks == article.body_blocks && updated_tile_blocks == article.tile_blocks

      article.update_columns(
        body_blocks: updated_body_blocks,
        tile_blocks: updated_tile_blocks,
        updated_at: Time.current
      )
    end
  end

  def down
    ContentArticle.reset_column_information
    ContentArticle.find_each do |article|
      updated_body_blocks = revert_blocks_font_sizes(article.body_blocks)
      updated_tile_blocks = revert_blocks_font_sizes(article.tile_blocks)

      next if updated_body_blocks == article.body_blocks && updated_tile_blocks == article.tile_blocks

      article.update_columns(
        body_blocks: updated_body_blocks,
        tile_blocks: updated_tile_blocks,
        updated_at: Time.current
      )
    end
  end

  private

  def convert_blocks_font_sizes(blocks)
    Array.wrap(blocks).map do |block|
      next block unless block.is_a?(Hash)

      content = block["content"].to_s
      converted = convert_font_size_pt_to_px(content)
      converted == content ? block : block.merge("content" => converted)
    end
  end

  def revert_blocks_font_sizes(blocks)
    Array.wrap(blocks).map do |block|
      next block unless block.is_a?(Hash)

      content = block["content"].to_s
      reverted = revert_font_size_px_to_pt(content)
      reverted == content ? block : block.merge("content" => reverted)
    end
  end

  def convert_font_size_pt_to_px(html)
    return html if html.blank?

    html.gsub(FONT_SIZE_PT_PATTERN) { "font-size: #{$1}px" }
  end

  def revert_font_size_px_to_pt(html)
    return html if html.blank?

    html.gsub(/font-size:\s*(\d+(?:\.\d+)?)\s*px/i) { "font-size: #{$1}pt" }
  end
end
