require 'xcodeproj'
require 'fileutils'
root = File.expand_path('../ios', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'LabelStudio.xcodeproj'))
app = project.new_target(:application, 'LabelStudio', :ios, '17.0')
tests = project.new_target(:unit_test_bundle, 'LabelStudioTests', :ios, '17.0')
ui = project.new_target(:ui_test_bundle, 'LabelStudioUITests', :ios, '17.0')
config_group = project.main_group.new_group('Config', 'Config')
defaults = config_group.new_file('Defaults.xcconfig')
tests.add_dependency(app)
ui.add_dependency(app)
[[app, 'LabelStudio'], [tests, 'LabelStudioTests'], [ui, 'LabelStudioUITests']].each do |target, name|
  group = project.main_group.new_group(name, name)
  Dir.glob(File.join(root, name, '**', '*.swift')).sort.each do |path|
    target.add_file_references([group.new_file(path.delete_prefix(File.join(root, name) + '/'))])
  end
  target.build_configurations.each do |config|
    config.base_configuration_reference = defaults
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.0', 'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
      'CODE_SIGN_STYLE' => 'Automatic',
      'PRODUCT_BUNDLE_IDENTIFIER' => "$(BUNDLE_ID_PREFIX).#{name}",
      'CURRENT_PROJECT_VERSION' => '1', 'MARKETING_VERSION' => '1.0',
      'TARGETED_DEVICE_FAMILY' => '1', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'SWIFT_EMIT_LOC_STRINGS' => 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES'
    })
  end
end
app.build_configurations.each do |config|
  config.build_settings.merge!({
    'GENERATE_INFOPLIST_FILE' => 'NO', 'INFOPLIST_FILE' => 'LabelStudio/Info.plist',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon', 'SUPPORTS_MACCATALYST' => 'NO',
    'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
  })
end
tests.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/LabelStudio.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LabelStudio'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
ui.build_configurations.each { |config| config.build_settings['TEST_TARGET_NAME'] = 'LabelStudio' }
appgroup = project.main_group.find_subpath('LabelStudio')
['Resources/Assets.xcassets', 'Resources/PrivacyInfo.xcprivacy'].each do |path|
  app.resources_build_phase.add_file_reference(appgroup.new_file(path))
end
testgroup = project.main_group.find_subpath('LabelStudioTests')
Dir.glob(File.join(root, 'LabelStudioTests', 'Resources', '*')).sort.each do |path|
  tests.resources_build_phase.add_file_reference(testgroup.new_file(path.delete_prefix(File.join(root, 'LabelStudioTests') + '/')))
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.add_test_target(ui)
scheme.set_launch_target(app)
scheme.save_as(File.join(root, 'LabelStudio.xcodeproj'), 'LabelStudio', true)
project.save
puts 'Generated LabelStudio.xcodeproj'
