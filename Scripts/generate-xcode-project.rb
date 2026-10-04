#!/usr/bin/env ruby
# Regenerates the checked-in native app/test project from Package.swift.
# Requires the development-only xcodeproj gem (1.27.x).

require 'json'
require 'open3'
require 'pathname'
require 'xcodeproj'

root = Pathname.new(__dir__).parent
project_path = root.join('MacPicard.xcodeproj')
manifest_json, diagnostics, status = Open3.capture3('swift', 'package', '--package-path', root.to_s, 'dump-package')
abort diagnostics unless status.success?
manifest = JSON.parse(manifest_json)
library_products = manifest.fetch('products').select { |product| product.fetch('type').key?('library') }.map { |product| product.fetch('name') }
app_manifest = manifest.fetch('targets').find { |target| target.fetch('name') == 'MacPicard' }
test_manifests = manifest.fetch('targets').select { |target| target.fetch('type') == 'test' }

project = Xcodeproj::Project.new(project_path.to_s, false, 77)
project.root_object.attributes['LastUpgradeCheck'] = '2600'
project.root_object.attributes['LastSwiftUpdateCheck'] = '2600'
project.root_object.development_region = 'en'
project.root_object.known_regions = ['en', 'Base']
project.build_configuration_list.default_configuration_name = 'Debug'

project.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'MACOSX_DEPLOYMENT_TARGET' => '26.0',
    'SDKROOT' => 'macosx',
    'SWIFT_VERSION' => '6.0',
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
    'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'nonisolated',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CODE_SIGN_STYLE' => 'Manual',
    'CODE_SIGN_IDENTITY' => '-',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO'
  )
end

package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '.'
project.root_object.package_references << package
project.main_group.new_group('Packages').new_file('Package.swift')
project.main_group.new_file('README.md')
project.main_group.new_file('.gitignore')
scripts_group = project.main_group.new_group('Scripts', 'Scripts')
Dir[root.join('Scripts/*').to_s].sort.each { |filename| scripts_group.new_file(File.basename(filename)) }
project.main_group.new_group('Documentation', 'docs').tap do |group|
  Dir[root.join('docs/*.md').to_s].sort.each { |filename| group.new_file(File.basename(filename)) }
end

def link_package_products(project, target, package, products)
  products.uniq.sort.each do |name|
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package
    dependency.product_name = name
    target.package_product_dependencies << dependency
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
  end
end

def add_swift_sources(root, group, target, directory)
  sources = Dir[root.join(directory, '**/*.swift').to_s].sort
  abort "No Swift sources in #{directory}" if sources.empty?
  sources.each do |filename|
    relative = Pathname.new(filename).relative_path_from(root.join(directory)).to_s
    target.source_build_phase.add_file_reference(group.new_file(relative))
  end
end

app = project.new_target(:application, 'MacPicard', :osx, '26.0')
app_group = project.main_group.new_group('MacPicard', app_manifest.fetch('path'))
add_swift_sources(root, app_group, app, app_manifest.fetch('path'))
link_package_products(project, app, package, library_products)
app.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.interlacedpixel.MacPicard',
    'PRODUCT_NAME' => 'MacPicard',
    'INFOPLIST_FILE' => 'Sources/MacPicard/Resources/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'SWIFT_OBJC_INTEROP_MODE' => 'objcxx',
    'DEFINES_MODULE' => 'YES',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    'ENABLE_APP_SANDBOX' => 'NO',
    'SKIP_INSTALL' => 'NO',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks']
  )
  configuration.build_settings['ENABLE_TESTABILITY'] = 'YES' if configuration.name == 'Debug'
end

resources = app_group.new_group('Resources', 'Resources')
resources.new_file('Info.plist')
resources.new_file('AppIcon.png')
localized = resources.new_variant_group('Localizable.strings')
localized.new_file('en.lproj/Localizable.strings').name = 'en'
app.resources_build_phase.add_file_reference(localized)

icon = app.new_shell_script_build_phase('Build App Icon')
icon.shell_path = '/bin/zsh'
icon.shell_script = '/bin/zsh "${SRCROOT}/Scripts/build-app-icon.sh" "${SRCROOT}/Sources/MacPicard/Resources/AppIcon.png" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AppIcon.icns"'
icon.input_paths = ['$(SRCROOT)/Scripts/build-app-icon.sh', '$(SRCROOT)/Sources/MacPicard/Resources/AppIcon.png']
icon.output_paths = ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppIcon.icns']

fingerprinting = app.new_shell_script_build_phase('Bundle Fingerprint Support')
fingerprinting.shell_path = '/bin/zsh'
fingerprinting.shell_script = '/bin/zsh "${SRCROOT}/Scripts/install-fingerprint-support.sh" "${TARGET_BUILD_DIR}/${WRAPPER_NAME}"'
# Always validate the publisher credential and pinned payload, including incremental/archive builds.
fingerprinting.always_out_of_date = '1'
fingerprinting.input_paths = ['$(SRCROOT)/Scripts/install-fingerprint-support.sh', '$(SRCROOT)/Sources/PicardFingerprint/Resources/Chromaprint/SHA256SUMS']
fingerprinting.output_paths = ['$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/fpcalc', '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AcoustID.plist']

tests_group = project.main_group.new_group('Tests', 'Tests')
tests = test_manifests.sort_by { |target| target.fetch('name') }.map do |definition|
  name = definition.fetch('name')
  target = project.new_target(:unit_test_bundle, name, :osx, '26.0')
  group = tests_group.new_group(name, name)
  add_swift_sources(root, group, target, definition.fetch('path'))
  dependencies = definition.fetch('dependencies').map { |dependency| dependency['byName']&.first }.compact
  # An app-hosted test links against the executable, not another copy of its
  # static package libraries. Package module search paths are still supplied.
  app_hosted = dependencies.include?('MacPicard')
  link_package_products(project, target, package, app_hosted ? [] : dependencies.select { |name| library_products.include?(name) })
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!(
      'PRODUCT_BUNDLE_IDENTIFIER' => "com.interlacedpixel.#{name}",
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'SWIFT_OBJC_INTEROP_MODE' => 'objcxx',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@loader_path/../Frameworks', '@executable_path/../Frameworks']
    )
    if app_hosted
      configuration.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/MacPicard.app/Contents/MacOS/MacPicard'
      configuration.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
      configuration.build_settings['SWIFT_INCLUDE_PATHS'] = ['$(inherited)', '$(BUILT_PRODUCTS_DIR)']
    end
  end
  if app_hosted
    target.add_dependency(app)
    project.root_object.attributes['TargetAttributes'] ||= {}
    project.root_object.attributes['TargetAttributes'][target.uuid] = { 'TestTargetID' => app.uuid }
  end
  target
end

# Frameworks must resolve against the selected SDK, not the generator gem's
# built-in SDK version or a developer's absolute Xcode installation path.
project.files.select { |file| file.path&.end_with?('Cocoa.framework') }.each do |file|
  file.path = 'System/Library/Frameworks/Cocoa.framework'
  file.source_tree = 'SDKROOT'
end

# Normalize string-valued target/proxy UUID references in the first pass;
# hash the normalized tree in the second pass for byte-stable regeneration.
project.predictabilize_uuids
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, nil, launch_target: true)
tests.each do |test|
  scheme.add_build_target(test, false)
  scheme.add_test_target(test)
end
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.testables.each { |test| test.parallelizable = false }
variables = scheme.test_action.xml_element.add_element('EnvironmentVariables')
variables.add_element('EnvironmentVariable', 'key' => 'MACPICARD_UNIT_TEST_HOST', 'value' => '1', 'isEnabled' => 'YES')
variables.add_element('EnvironmentVariable', 'key' => 'PATH', 'value' => '$(PATH):/opt/homebrew/bin:/usr/local/bin', 'isEnabled' => 'YES')
%w[MACPICARD_LIVE_API_TESTS MACPICARD_LIVE_COVER_ART_TEST MACPICARD_TRASH_INTEGRATION_TEST MACPICARD_CROSS_VOLUME_TEST].each do |name|
  variables.add_element('EnvironmentVariable', 'key' => name, 'value' => '1', 'isEnabled' => 'NO')
end
scheme.launch_action.build_configuration = 'Debug'
scheme.profile_action.build_configuration = 'Release'
scheme.archive_action.build_configuration = 'Release'
# The package also exposes a MacPicard executable scheme. Give the native
# .app scheme a distinct name so Run/Archive cannot select the CLI by mistake.
scheme.save_as(project_path.to_s, 'MacPicard App', true)
puts "Generated #{project_path} with #{tests.length} test targets."
