# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductLocalImages do
  describe ".preview_rel_path" do
    it "derives preview path from full webp path" do
      full = "/images/products/aa/bb/cc/abc123.webp"
      expect(described_class.preview_rel_path(full)).to eq("/images/products/aa/bb/cc/abc123_preview.webp")
    end

    it "returns path unchanged for non-local urls" do
      url = "https://www.ikea.com/foo.webp"
      expect(described_class.preview_rel_path(url)).to eq(url)
    end

    it "returns preview path unchanged when already preview" do
      preview = "/images/products/aa/bb/cc/abc123_preview.webp"
      expect(described_class.preview_rel_path(preview)).to eq(preview)
    end
  end

  describe ".preview_paths" do
    it "returns preview paths when preview file exists" do
      full_rel = "/images/products/te/st/ab/testhash1234567890abcdef1234567890ab.webp"
      preview_rel = "/images/products/te/st/ab/testhash1234567890abcdef1234567890ab_preview.webp"

      full_abs = Rails.public_path.join(full_rel.delete_prefix("/"))
      preview_abs = Rails.public_path.join(preview_rel.delete_prefix("/"))
      FileUtils.mkdir_p(File.dirname(full_abs))
      File.binwrite(full_abs, "full-image")
      File.binwrite(preview_abs, "preview-image")

      result = described_class.preview_paths([full_rel])

      expect(result).to eq([preview_rel])
    ensure
      FileUtils.rm_f(full_abs)
      FileUtils.rm_f(preview_abs)
    end

    it "falls back to full path when preview is missing" do
      full_rel = "/images/products/te/st/cd/missingpreviewhash1234567890ab.webp"
      result = described_class.preview_paths([full_rel])
      expect(result).to eq([full_rel])
    end
  end
end
