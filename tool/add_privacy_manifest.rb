# Adds PrivacyInfo.xcprivacy to the Runner target's Resources build phase in
# both Xcode projects (P3 #31). Idempotent — re-running is a no-op.
#
#   ruby tool/add_privacy_manifest.rb
#
# Kept in the repo because `flutter create` regenerating a project, or a merge
# resolving project.pbxproj the wrong way, silently drops the manifest — and a
# dropped manifest is only discovered when App Store Connect rejects the build.
require 'xcodeproj'

{
  'ios/Runner.xcodeproj'   => 'Runner',
  'macos/Runner.xcodeproj' => 'Runner',
}.each do |project_path, target_name|
  project = Xcodeproj::Project.open(project_path)
  target  = project.targets.find { |t| t.name == target_name }
  group   = project.main_group.find_subpath(target_name, true)

  ref = group.files.find { |f| f.path == 'PrivacyInfo.xcprivacy' } ||
        group.new_file('PrivacyInfo.xcprivacy')

  already = target.resources_build_phase.files.any? { |bf| bf.file_ref == ref }
  target.resources_build_phase.add_file_reference(ref) unless already

  project.save
  puts "#{project_path}: #{already ? 'already present' : 'added'}"
end
