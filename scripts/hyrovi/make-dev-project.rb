#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

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

client.build_configurations.each do |config|
  next unless config.name == "Debug"

  config.build_settings["DEVELOPMENT_TEAM"] = "VTZMACGB4B"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
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
