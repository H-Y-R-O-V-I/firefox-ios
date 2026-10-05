#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"
require "pathname"

ROOT = File.expand_path("../..", __dir__)
SOURCE = File.join(ROOT, "firefox-ios", "Client.xcodeproj")
DEST = File.join(ROOT, "firefox-ios", "HYROVIClient.xcodeproj")
MAIN_TARGET = "Client"
DISABLED_EXTENSIONS = %w[
  CredentialProvider
  NotificationService
  ShareTo
  WidgetKitExtension
  Sticker
  ActionExtension
].freeze

FileUtils.rm_rf(DEST)
FileUtils.cp_r(SOURCE, DEST)

project = Xcodeproj::Project.open(DEST)
client = project.targets.find { |target| target.name == MAIN_TARGET }
abort "Client target missing" unless client

# Add HYROVI browser integration sources only to the generated development
# project. The upstream Client.xcodeproj stays easy to rebase against Mozilla.
hyrovi_sources_root = File.join(ROOT, "firefox-ios", "Client", "HYROVI")
hyrovi_group = project.main_group.find_subpath("HYROVI Sources", true)
Dir[File.join(hyrovi_sources_root, "*.swift")].sort.each do |source_path|
  relative_path = Pathname.new(source_path)
                          .relative_path_from(Pathname.new(File.join(ROOT, "firefox-ios")))
                          .to_s
  file_ref = hyrovi_group.new_file(relative_path)
  client.source_build_phase.add_file_reference(file_ref, true)
end

# The personal HYROVI development team cannot receive Mozilla's restricted
# Default Browser / Browser Installation / Push / Autofill capabilities.
target_attributes = project.root_object.attributes["TargetAttributes"] ||= {}
client_attributes = target_attributes[client.uuid] ||= {}
client_attributes["SystemCapabilities"] = {}

# Keep Firefox's internal frameworks, but skip optional app extensions for the
# first HYROVI device build. Production capabilities can be restored later
# when Apple grants the matching entitlements to the HYROVI team.
client.dependencies.delete_if do |dependency|
  target = dependency.target
  target && DISABLED_EXTENSIONS.include?(target.name)
end

client.copy_files_build_phases.each do |phase|
  next unless phase.name == "Embed App Extensions"

  phase.files.delete_if do |build_file|
    ref = build_file.file_ref
    path = ref&.path.to_s
    DISABLED_EXTENSIONS.any? { |name| path == "#{name}.appex" }
  end
end

# Every product that participates in the local Debug build must use the HYROVI
# development team. Upstream assigns Mozilla team identifiers to internal
# frameworks as well as the app target, so changing only Client is not enough
# for a physical-device build.
project.targets.each do |target|
  target.build_configurations.each do |config|
    next unless config.name == "Debug"

    settings = config.build_settings
    settings["DEVELOPMENT_TEAM"] = "VTZMACGB4B"
    settings.delete("DEVELOPMENT_TEAM[sdk=iphoneos*]")
    settings["CODE_SIGN_STYLE"] = "Automatic"
  end
end

client.build_configurations.each do |config|
  next unless config.name == "Debug"

  config.build_settings["CODE_SIGN_ENTITLEMENTS"] =
    "Client/Entitlements/HYROVIDev.entitlements"
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(client)
scheme.set_launch_target(client)
scheme.save_as(DEST, "HYROVI Browser Dev", true)

puts DEST
puts "Client dependencies: #{client.dependencies.map { |d| d.target&.name }.compact.join(", ")}"
