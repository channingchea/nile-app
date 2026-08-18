# Keeps hand-added files wired into the Xcode projects. Idempotent.
#
#   ruby tool/sync_xcode_project.rb
#
# Checked in because `flutter create` regenerating a project, or a merge
# resolving project.pbxproj the wrong way, drops these silently — and a dropped
# privacy manifest is only discovered when App Store Connect rejects the build.
#
#   PrivacyInfo.xcprivacy   → Resources, both iOS and macOS (P3 #31)
#   AgeSignalsChannel.swift → Sources, iOS only. UIKit-based, and the macOS
#                             build is direct-download rather than Mac App
#                             Store, so it has no equivalent obligation. (P4)
require 'xcodeproj'

RESOURCES = {
  'ios/Runner.xcodeproj'   => ['PrivacyInfo.xcprivacy'],
  'macos/Runner.xcodeproj' => ['PrivacyInfo.xcprivacy'],
}.freeze

SOURCES = {
  'ios/Runner.xcodeproj' => ['AgeSignalsChannel.swift'],
}.freeze

def ensure_file(project, target, group, filename, phase)
  ref = group.files.find { |f| f.path == filename } || group.new_file(filename)
  already = phase.files.any? { |bf| bf.file_ref == ref }
  phase.add_file_reference(ref) unless already
  already
end

(RESOURCES.keys | SOURCES.keys).each do |project_path|
  project = Xcodeproj::Project.open(project_path)
  target  = project.targets.find { |t| t.name == 'Runner' }
  group   = project.main_group.find_subpath('Runner', true)
  changes = []

  RESOURCES.fetch(project_path, []).each do |filename|
    already = ensure_file(project, target, group, filename, target.resources_build_phase)
    changes << "#{filename} (resource, #{already ? 'already present' : 'added'})"
  end

  SOURCES.fetch(project_path, []).each do |filename|
    already = ensure_file(project, target, group, filename, target.source_build_phase)
    changes << "#{filename} (source, #{already ? 'already present' : 'added'})"
  end

  project.save
  puts "#{project_path}: #{changes.join(', ')}"
end
