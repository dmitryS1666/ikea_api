# frozen_string_literal: true

namespace :bundle do
  desc "Bootstrap included bundle components for parent SKU (e.g. rake bundle:bootstrap[s29545213])"
  task :bootstrap, [:sku] => :environment do |_t, args|
    sku = args[:sku].to_s.strip
    abort "Usage: rake bundle:bootstrap[s29545213]" if sku.blank?

    parent = Products::ListingSkuResolver.find_product(sku)
    abort "Product not found for SKU #{sku}" unless parent

    puts "Parent: #{parent.sku} (#{parent.name})"
    puts "included_products before: #{Array(parent.included_products).inspect}"

    Products::IncludedProductsBootstrapService.ensure!(parent)

    parent.reload
    articles = Products::ArticleNumber.normalize_list(parent.included_products)
    puts "included_products after: #{articles.inspect}"

    articles.each do |article|
      child = Products::IncludedProductsBootstrapService.component_product_for(article)
      puts child ? "  OK #{article} -> #{child.sku} #{child.name}" : "  MISSING #{article} (expected sku s#{article})"
    end
  end
end
