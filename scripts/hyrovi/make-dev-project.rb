#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"
require "pathname"

ROOT = File.expand_path("../..", __dir__)
SOURCE = File.join(ROOT, "firefox-ios", "Client.xcodeproj")
DEST = File.join(ROOT, "firefox-ios", "HYROVIClient.xcodeproj")
MAIN_TARGET = "Client"
ENGINE_CORE_DIR = File.join(ROOT, "firefox-ios", "Client", "HYROVI", "EngineCore")
ENGINE_CORE_LIB = File.join(ENGINE_CORE_DIR, "libhyrovi_engine.a")
ENGINE_CORE_INCLUDE = File.join(ENGINE_CORE_DIR, "include")
ENGINE_BUILD_SCRIPT = File.join(ROOT, "scripts", "hyrovi", "build-engine-core.sh")
DISABLED_EXTENSIONS = %w[
  CredentialProvider
  NotificationService
  ShareTo
  WidgetKitExtension
  Sticker
  ActionExtension
].freeze

unless File.exist?(ENGINE_CORE_LIB) &&
       File.exist?(File.join(ENGINE_CORE_INCLUDE, "hyrovi_engine.h")) &&
       File.exist?(File.join(ENGINE_CORE_INCLUDE, "module.modulemap"))
  abort "HYROVI Engine core build failed" unless system(ENGINE_BUILD_SCRIPT)
end

def append_build_setting(config, key, value)
  current = config.build_settings[key]
  values =
    case current
    when Array then current.dup
    when String then current.split(" ")
    else []
    end
  values.unshift("$(inherited)") unless values.include?("$(inherited)")
  values << value unless values.include?(value)
  config.build_settings[key] = values
end

FileUtils.rm_rf(DEST)
FileUtils.cp_r(SOURCE, DEST)

project = Xcodeproj::Project.open(DEST)
client = project.targets.find { |target| target.name == MAIN_TARGET }
abort "Client target missing" unless client

hyrovi_sources_root = File.join(ROOT, "firefox-ios", "Client", "HYROVI")
hyrovi_group = project.main_group.find_subpath("HYROVI Sources", true)
Dir[File.join(hyrovi_sources_root, "*.swift")].sort.each do |source_path|
  relative_path = Pathname.new(source_path)
                          .relative_path_from(Pathname.new(File.join(ROOT, "firefox-ios")))
                          .to_s
  file_ref = hyrovi_group.new_file(relative_path)
  client.source_build_phase.add_file_reference(file_ref, true)
end

engine_group = hyrovi_group.new_group(
  "EngineCore",
  File.join("Client", "HYROVI", "EngineCore")
)
engine_lib_ref = engine_group.new_file("libhyrovi_engine.a")
client.frameworks_build_phase.add_file_reference(engine_lib_ref, true)

include_path = "$(PROJECT_DIR)/Client/HYROVI/EngineCore/include"
library_path = "$(PROJECT_DIR)/Client/HYROVI/EngineCore"
client.build_configurations.each do |config|
  append_build_setting(config, "HEADER_SEARCH_PATHS", include_path)
  append_build_setting(config, "SWIFT_INCLUDE_PATHS", include_path)
  append_build_setting(config, "LIBRARY_SEARCH_PATHS", library_path)
end

target_attributes = project.root_object.attributes["TargetAttributes"] ||= {}
client_attributes = target_attributes[client.uuid] ||= {}
client_attributes["SystemCapabilities"] = {}

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
puts "HYROVI Engine core: #{ENGINE_CORE_LIB}"
