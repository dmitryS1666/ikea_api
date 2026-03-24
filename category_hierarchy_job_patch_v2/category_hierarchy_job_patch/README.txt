Files for safe category hierarchy import:

- app/services/category_hierarchy_import/importer.rb
- app/jobs/import_category_hierarchy_job.rb
- lib/tasks/category_hierarchy.rake

What this patch now does:
- updates parent_ids / translated_name / is_deleted for categories present in import JSON
- keeps ikea_id unchanged
- can soft-delete active categories missing from import, but only when they have no live references
- purges icon / pictogram / background_image and remote/local image paths only for safe-to-delete orphan categories
- normalizes visual assets after hierarchy import:
  - level 1 (root) categories should keep pictogram
  - level 2 categories should keep icon
  - deeper categories should not keep icon/pictogram
  - if target category has no needed asset, importer copies it from source occurrences listed in JSON

Recommended order:

1) Dry run
   bundle exec rake category_hierarchy:dry_run[/absolute/path/to/json]

2) Review report in tmp/category_hierarchy_import/*.json
   Pay attention to:
   - errors
   - orphan_candidates
   - visual_asset_actions

3) First apply without deleting missing categories
   bundle exec rake category_hierarchy:apply[/absolute/path/to/json] CONFIRM=YES

4) Only after report review, optional cleanup run
   bundle exec rake category_hierarchy:apply[/absolute/path/to/json] CONFIRM=YES SOFT_DELETE_MISSING=true PURGE_DELETED_ASSETS=true

Useful flags:
- SOFT_DELETE_MISSING=true          soft-delete active categories missing from import when no references remain
- PURGE_DELETED_ASSETS=true         purge icon/pictogram/background_image for safe-to-delete orphans
- UPDATE_ORIGINAL_NAME=true         also update categories.name from original_name
- NON_STRICT=true                   do not abort on validation errors
- NORMALIZE_VISUAL_ASSETS=false     disable level-based visual asset normalization
- PURGE_MISPLACED_VISUALS=false     keep icon/pictogram even if category moved to another level

Safe default:
- NORMALIZE_VISUAL_ASSETS=true
- PURGE_MISPLACED_VISUALS=true
- SOFT_DELETE_MISSING=false
- PURGE_DELETED_ASSETS=false
