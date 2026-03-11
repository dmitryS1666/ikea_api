namespace :category_cleanup do
  desc '1. Import cleanup rules from categories_docs/catalog_1.ods'
  task import_rules: :environment do
    CategoryCleanup::ImportRules.new.call
    puts "Imported rules: #{CategoryCleanupRule.count}"
  end

  desc '2. Build row mappings from categories_docs/catalog_2.ods'
  task build_row_mappings: :environment do
    CategoryCleanup::BuildRowMappings.new.call
    puts "Built row mappings: #{CategoryCatalogRowMapping.count}"
  end

  desc '3. Resolve source/target categories for rules'
  task resolve_rules: :environment do
    CategoryCleanup::ResolveRules.new.call
    puts "Resolved: #{CategoryCleanupRule.where(resolution_status: 'resolved').count}"
    puts "Failed/Ambiguous: #{CategoryCleanupRule.where.not(resolution_status: 'resolved').count}"
  end

  desc '4. Print dry-run report'
  task dry_run: :environment do
    report = CategoryCleanup::DryRun.new.call
    pp report
  end

  desc '5. Apply cleanup changes'
  task apply: :environment do
    blocking_statuses = %w[pending failed]
    blocking_count = CategoryCleanupRule.where(resolution_status: blocking_statuses).count

    if blocking_count.positive?
      abort "There are #{blocking_count} blocking rules with statuses: #{blocking_statuses.join(', ')}"
    end

    puts "Resolved:  #{CategoryCleanupRule.where(resolution_status: 'resolved').count}"
    puts "Skipped:   #{CategoryCleanupRule.where(resolution_status: 'skipped').count}"
    puts "Ambiguous: #{CategoryCleanupRule.where(resolution_status: 'ambiguous').count}"
    puts "Applying only resolved delete/merge rules..."

    CategoryCleanup::Apply.new.call!
    puts "Cleanup applied."
  end
end
