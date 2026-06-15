# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::GenerateImagePreviewService do
  describe "#call" do
    let(:full_rel) { "/images/products/te/st/ab/testhash1234567890abcdef1234567890ab.webp" }
    let(:full_abs) { Rails.public_path.join(full_rel.delete_prefix("/")) }
    let(:preview_abs) { Rails.public_path.join("#{full_rel.delete_prefix('/').sub(/\.webp\z/, '_preview.webp')}") }

    before do
      FileUtils.mkdir_p(File.dirname(full_abs))
    end

    after do
      FileUtils.rm_f(full_abs)
      FileUtils.rm_f(preview_abs)
    end

    it "generates preview webp next to source file" do
      skip "cwebp is not installed" unless cwebp_available?

      status = system("convert", "-size", "800x800", "xc:red", full_abs.to_s)
      skip "ImageMagick convert is not available" unless status

      result = described_class.new(source_path: full_abs).call

      expect(result.error).to be_nil
      expect(result.generated).to eq(true)
      expect(File).to exist(preview_abs)
      expect(File.size(preview_abs)).to be <= 20.kilobytes
    end

    it "skips when preview is newer than source" do
      File.binwrite(full_abs, "source")
      FileUtils.mkdir_p(File.dirname(preview_abs))
      File.binwrite(preview_abs, "preview")
      FileUtils.touch(preview_abs, mtime: Time.current + 60)

      result = described_class.new(source_path: full_abs).call

      expect(result.skipped).to eq(true)
      expect(result.generated).to eq(false)
    end
  end

  def cwebp_available?
    _stdout, _stderr, status = Open3.capture3("cwebp", "-version")
    status.success?
  end
end
