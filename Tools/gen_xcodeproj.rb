#!/usr/bin/env ruby
# frozen_string_literal: true

# gen_xcodeproj.rb — reproducible generator for BornlessRitual.xcodeproj.
#
# Runs on Linux (no Xcode needed) and produces a project that Xcode 15/16 on macOS
# opens and builds as-is. The .xcodeproj is a pure derived artifact: it is rebuilt
# from scratch on every run from the on-disk source tree, then all object UUIDs are
# replaced by MD5s of their object paths (Xcodeproj#predictabilize_uuids), so two runs
# over the same tree produce byte-identical output.
#
# Usage (from anywhere):
#   ruby Tools/gen_xcodeproj.rb                # generate + validate
#   ruby Tools/gen_xcodeproj.rb --check        # generate into a temp dir, fail if it differs from the committed project
#   ruby Tools/gen_xcodeproj.rb --force-scaffold  # rewrite Info.plist, bridging header and asset catalog stubs
#
# Scaffold files (Info.plist, bridging header, Assets.xcassets) are written only when
# missing so hand edits survive re-runs; the .xcodeproj and shared scheme are always
# rewritten. See Tools/README.md.

require 'xcodeproj'
require 'json'
require 'zlib'
require 'find'
require 'fileutils'
require 'pathname'
require 'optparse'
require 'rexml/document'
require 'tmpdir'

module GenXcodeproj
  ROOT = Pathname.new(__dir__).parent.expand_path
  APP_NAME = 'BornlessRitual'
  APP_DIR = ROOT + APP_NAME
  PROJECT_PATH = ROOT + "#{APP_NAME}.xcodeproj"
  BUNDLE_ID = 'com.bornless.ritual'
  DISPLAY_NAME = 'Bornless Ritual'
  DEPLOYMENT_TARGET = '17.0'
  PACKAGE_RELATIVE_PATH = 'Packages/RitualCore'
  PACKAGE_PRODUCT = 'RitualCore'
  # Explicit SDK framework links requested for the Frameworks phase (sorted, deterministic).
  SDK_FRAMEWORKS = %w[CoreHaptics Metal MetalFX MetalKit].freeze
  # Empty source directories are created so the layout exists on a fresh checkout.
  SOURCE_DIRS = %w[App Render Shaders Interaction Capture Resources].freeze
  # objectVersion 60 == "Xcode 15.0" compatibility: first format that natively carries
  # XCLocalSwiftPackageReference; Xcode 16 opens it without an upgrade prompt.
  OBJECT_VERSION = 60
  XCODE_VERSION_STAMP = '1600'
  TOOLS_VERSION_STAMP = '15.0'
  SHADER_HEADER_DIR = "$(SRCROOT)/#{APP_NAME}/Shaders"
  BRIDGING_HEADER = "#{APP_NAME}/#{APP_NAME}-Bridging-Header.h"
  INFO_PLIST = "#{APP_NAME}/Info.plist"
  LAUNCH_ARGUMENT_EXAMPLE = '-stage 7 -camera threequarter -renderPath rt -seed 1 -capture stills'

  # Resource files copied into the bundle. Anything else under Resources/ is reported
  # and skipped so a stray file never silently changes the app bundle.
  RESOURCE_FILE_EXTENSIONS = %w[.json .txt .plist .strings .png .jpg .jpeg .heic .wav .caf .m4a .mp3 .mov .mp4 .ttf .otf .md].freeze
  # Directory bundles referenced as a single file reference (Xcode compiles them itself).
  RESOURCE_FOLDER_EXTENSIONS = %w[.xcassets .bundle .scnassets .xcstrings .mlmodelc].freeze

  # File types the gem does not know (Constants::FILE_TYPES_BY_EXTENSION has no entry).
  EXTRA_FILE_TYPES = {
    '.metal' => 'sourcecode.metal',
    '.json' => 'text.json',
    '.txt' => 'text',
    '.md' => 'net.daringfireball.markdown',
    '.jpg' => 'image.jpeg',
    '.jpeg' => 'image.jpeg',
    '.heic' => 'image.heic',
    '.wav' => 'audio.wav',
    '.caf' => 'audio.caf',
    '.m4a' => 'audio.m4a',
    '.mp4' => 'video.mp4',
    '.ttf' => 'file',
    '.otf' => 'file',
    '.scnassets' => 'wrapper.scnassets',
    '.xcstrings' => 'text.json.xcstrings',
    '.mlmodelc' => 'folder',
  }.freeze

  # ---------------------------------------------------------------------------
  # Build settings
  # ---------------------------------------------------------------------------

  SHARED_TOOLCHAIN_SETTINGS = {
    'DEAD_CODE_STRIPPING' => 'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'HEADER_SEARCH_PATHS' => ['$(inherited)', SHADER_HEADER_DIR],
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
    'MTL_FAST_MATH' => 'YES',
    'MTL_HEADER_SEARCH_PATHS' => ['$(inherited)', SHADER_HEADER_DIR],
    # Metal 3.1 is the language level that ships with iOS 17 / Xcode 15; the enum values
    # Xcode accepts are UseDeploymentTarget, Metal11 ... Metal24, Metal30, Metal31, Metal32.
    'MTL_LANGUAGE_REVISION' => 'Metal31',
    'SDKROOT' => 'iphoneos',
    'SWIFT_STRICT_CONCURRENCY' => 'minimal',
    'SWIFT_VERSION' => '5.0',
  }.freeze

  SHARED_DEBUG_SETTINGS = {
    'ENABLE_TESTABILITY' => 'YES',
    'MTL_ENABLE_DEBUG_INFO' => 'INCLUDE_SOURCE',
    'SWIFT_OPTIMIZATION_LEVEL' => '-Onone',
  }.freeze

  SHARED_RELEASE_SETTINGS = {
    'MTL_ENABLE_DEBUG_INFO' => 'NO',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'SWIFT_OPTIMIZATION_LEVEL' => '-O',
  }.freeze

  PROJECT_SETTINGS = {
    all: {
      'ALWAYS_SEARCH_USER_PATHS' => 'NO',
      'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS' => 'YES',
      'CLANG_ANALYZER_NONNULL' => 'YES',
      'CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION' => 'YES_AGGRESSIVE',
      'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++20',
      'CLANG_ENABLE_MODULES' => 'YES',
      'CLANG_ENABLE_OBJC_ARC' => 'YES',
      'CLANG_ENABLE_OBJC_WEAK' => 'YES',
      'CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING' => 'YES',
      'CLANG_WARN_BOOL_CONVERSION' => 'YES',
      'CLANG_WARN_COMMA' => 'YES',
      'CLANG_WARN_CONSTANT_CONVERSION' => 'YES',
      'CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS' => 'YES',
      'CLANG_WARN_DIRECT_OBJC_ISA_USAGE' => 'YES_ERROR',
      'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'YES',
      'CLANG_WARN_EMPTY_BODY' => 'YES',
      'CLANG_WARN_ENUM_CONVERSION' => 'YES',
      'CLANG_WARN_INFINITE_RECURSION' => 'YES',
      'CLANG_WARN_INT_CONVERSION' => 'YES',
      'CLANG_WARN_NON_LITERAL_NULL_CONVERSION' => 'YES',
      'CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF' => 'YES',
      'CLANG_WARN_OBJC_LITERAL_CONVERSION' => 'YES',
      'CLANG_WARN_OBJC_ROOT_CLASS' => 'YES_ERROR',
      'CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER' => 'YES',
      'CLANG_WARN_RANGE_LOOP_ANALYSIS' => 'YES',
      'CLANG_WARN_STRICT_PROTOTYPES' => 'YES',
      'CLANG_WARN_SUSPICIOUS_MOVE' => 'YES',
      'CLANG_WARN_UNGUARDED_AVAILABILITY' => 'YES_AGGRESSIVE',
      'CLANG_WARN_UNREACHABLE_CODE' => 'YES',
      'CLANG_WARN__DUPLICATE_METHOD_MATCH' => 'YES',
      'COPY_PHASE_STRIP' => 'NO',
      'ENABLE_STRICT_OBJC_MSGSEND' => 'YES',
      'GCC_C_LANGUAGE_STANDARD' => 'gnu17',
      'GCC_NO_COMMON_BLOCKS' => 'YES',
      'GCC_WARN_64_TO_32_BIT_CONVERSION' => 'YES',
      'GCC_WARN_ABOUT_RETURN_TYPE' => 'YES_ERROR',
      'GCC_WARN_UNDECLARED_SELECTOR' => 'YES',
      'GCC_WARN_UNINITIALIZED_AUTOS' => 'YES_AGGRESSIVE',
      'GCC_WARN_UNUSED_FUNCTION' => 'YES',
      'GCC_WARN_UNUSED_VARIABLE' => 'YES',
      'LOCALIZATION_PREFERS_STRING_CATALOGS' => 'YES',
    }.merge(SHARED_TOOLCHAIN_SETTINGS),
    debug: {
      'DEBUG_INFORMATION_FORMAT' => 'dwarf',
      'GCC_DYNAMIC_NO_PIC' => 'NO',
      'GCC_OPTIMIZATION_LEVEL' => '0',
      'GCC_PREPROCESSOR_DEFINITIONS' => ['DEBUG=1', '$(inherited)'],
      'ONLY_ACTIVE_ARCH' => 'YES',
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => ['DEBUG', '$(inherited)'],
    }.merge(SHARED_DEBUG_SETTINGS),
    release: {
      'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
      'ENABLE_NS_ASSERTIONS' => 'NO',
      'VALIDATE_PRODUCT' => 'YES',
    }.merge(SHARED_RELEASE_SETTINGS),
  }.freeze

  TARGET_SETTINGS = {
    all: {
      'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
      'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
      'CODE_SIGN_STYLE' => 'Automatic',
      'CURRENT_PROJECT_VERSION' => '1',
      'DEVELOPMENT_TEAM' => '',
      'ENABLE_PREVIEWS' => 'YES',
      'GENERATE_INFOPLIST_FILE' => 'NO',
      'INFOPLIST_FILE' => INFO_PLIST,
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
      'MARKETING_VERSION' => '1.0',
      'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
      'PRODUCT_NAME' => '$(TARGET_NAME)',
      'SUPPORTS_MACCATALYST' => 'NO',
      'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
      'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
      'SWIFT_EMIT_LOC_STRINGS' => 'YES',
      'SWIFT_OBJC_BRIDGING_HEADER' => BRIDGING_HEADER,
      'TARGETED_DEVICE_FAMILY' => '1',
    }.merge(SHARED_TOOLCHAIN_SETTINGS),
    debug: SHARED_DEBUG_SETTINGS,
    release: SHARED_RELEASE_SETTINGS,
  }.freeze

  # ---------------------------------------------------------------------------
  # Source tree scan
  # ---------------------------------------------------------------------------

  # Everything the project references, as paths relative to BornlessRitual/ (sorted).
  SourceTree = Struct.new(:swift, :metal, :shader_headers, :resources, :skipped, keyword_init: true)

  module Scanner
    module_function

    def scan(app_dir = APP_DIR)
      resources, skipped = scan_resources(app_dir)
      SourceTree.new(
        swift: relative_glob(app_dir, '**/*.swift'),
        metal: relative_glob(app_dir, 'Shaders/*.metal'),
        shader_headers: relative_glob(app_dir, 'Shaders/*.h'),
        resources: resources,
        skipped: skipped,
      )
    end

    def relative_glob(base, pattern)
      Dir.glob(pattern, base: base.to_s).map { |path| Pathname.new(path) }.sort
    end

    # Resources/**: folder bundles (.xcassets ...) become one reference, regular files are
    # matched against RESOURCE_FILE_EXTENSIONS. Hidden files/dirs are ignored.
    # Returns [resources, skipped], both sorted and relative to app_dir.
    def scan_resources(app_dir)
      resources_dir = app_dir + 'Resources'
      return [[], []] unless resources_dir.directory?

      found = []
      skipped = []
      Find.find(resources_dir.to_s) do |entry|
        path = Pathname.new(entry)
        next if path == resources_dir
        Find.prune if path.basename.to_s.start_with?('.')

        if path.directory? && RESOURCE_FOLDER_EXTENSIONS.include?(path.extname.downcase)
          found << path.relative_path_from(app_dir)
          Find.prune
        elsif path.file?
          bucket = RESOURCE_FILE_EXTENSIONS.include?(path.extname.downcase) ? found : skipped
          bucket << path.relative_path_from(app_dir)
        end
      end
      [found.sort, skipped.sort]
    end
  end

  # ---------------------------------------------------------------------------
  # Scaffold: files the project references but which are hand-maintained afterwards
  # ---------------------------------------------------------------------------

  module Scaffold
    module_function

    def run(force: false, log: method(:puts))
      SOURCE_DIRS.each { |dir| FileUtils.mkdir_p(APP_DIR + dir) }
      write_if_missing(APP_DIR + 'Info.plist', info_plist_xml, force, log)
      write_if_missing(APP_DIR + "#{APP_NAME}-Bridging-Header.h", bridging_header, force, log)
      catalog = APP_DIR + 'Resources' + 'Assets.xcassets'
      write_if_missing(catalog + 'Contents.json', catalog_root_json, force, log)
      write_if_missing(catalog + 'AppIcon.appiconset' + 'Contents.json', app_icon_json, force, log)
      write_if_missing(catalog + 'AppIcon.appiconset' + 'AppIcon.png', -> { placeholder_icon_png(1024) }, force, log)
      write_if_missing(catalog + 'AccentColor.colorset' + 'Contents.json', accent_color_json, force, log)
    end

    def write_if_missing(path, content, force, log)
      return if path.exist? && !force

      FileUtils.mkdir_p(path.dirname)
      bytes = content.respond_to?(:call) ? content.call : content
      File.binwrite(path, bytes)
      log.call("  scaffold: wrote #{path.relative_path_from(ROOT)}")
    end

    def bridging_header
      <<~HEADER
        //
        //  #{APP_NAME}-Bridging-Header.h
        //  Exposes the Swift<->MSL shared layouts (ShaderTypes.h) to Swift. ShaderTypes.h
        //  is authored separately in Shaders/; the path is relative to this header's directory
        //  and also resolvable through HEADER_SEARCH_PATHS = $(SRCROOT)/#{APP_NAME}/Shaders.
        //

        #ifndef #{APP_NAME}_Bridging_Header_h
        #define #{APP_NAME}_Bridging_Header_h

        #include "Shaders/ShaderTypes.h"

        #endif /* #{APP_NAME}_Bridging_Header_h */
      HEADER
    end

    def info_plist_hash
      {
        'CFBundleDevelopmentRegion' => '$(DEVELOPMENT_LANGUAGE)',
        'CFBundleDisplayName' => DISPLAY_NAME,
        'CFBundleExecutable' => '$(EXECUTABLE_NAME)',
        'CFBundleIdentifier' => '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleInfoDictionaryVersion' => '6.0',
        'CFBundleName' => '$(PRODUCT_NAME)',
        'CFBundlePackageType' => 'APPL',
        'CFBundleShortVersionString' => '$(MARKETING_VERSION)',
        'CFBundleVersion' => '$(CURRENT_PROJECT_VERSION)',
        'LSRequiresIPhoneOS' => true,
        'LSSupportsOpeningDocumentsInPlace' => true,
        'UIApplicationSceneManifest' => { 'UIApplicationSupportsMultipleScenes' => false },
        'UIApplicationSupportsIndirectInputEvents' => true,
        'UIFileSharingEnabled' => true,
        'UILaunchScreen' => {},
        'UIRequiredDeviceCapabilities' => %w[metal arm64],
        'UISupportedInterfaceOrientations' => %w[
          UIInterfaceOrientationPortrait
          UIInterfaceOrientationLandscapeLeft
          UIInterfaceOrientationLandscapeRight
        ],
      }
    end

    def info_plist_xml
      body = PlistXML.render(info_plist_hash, 0)
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        #{body}
        </plist>
      PLIST
    end

    def catalog_root_json
      pretty_json('info' => { 'author' => 'xcode', 'version' => 1 })
    end

    def app_icon_json
      pretty_json(
        'images' => [
          { 'filename' => 'AppIcon.png', 'idiom' => 'universal', 'platform' => 'ios', 'size' => '1024x1024' },
        ],
        'info' => { 'author' => 'xcode', 'version' => 1 },
      )
    end

    def accent_color_json
      pretty_json(
        'colors' => [
          {
            'color' => {
              'color-space' => 'srgb',
              'components' => { 'alpha' => '1.000', 'blue' => '0.150', 'green' => '0.600', 'red' => '0.950' },
            },
            'idiom' => 'universal',
          },
        ],
        'info' => { 'author' => 'xcode', 'version' => 1 },
      )
    end

    def pretty_json(hash)
      JSON.pretty_generate(hash) + "\n"
    end

    # 1024x1024 opaque RGB PNG: dark red at the top fading to black, with a soft
    # radial ember glow — no alpha channel (App Store icons must be opaque). Pure
    # Ruby + Zlib; output is deterministic.
    def placeholder_icon_png(size)
      rows = String.new(capacity: size * (size * 3 + 1), encoding: Encoding::BINARY)
      center = (size - 1) / 2.0
      size.times do |y|
        rows << 0.chr
        vertical = 1.0 - (y / (size - 1.0))
        row = Array.new(size * 3)
        size.times do |x|
          dx = (x - center) / center
          dy = (y - center) / center
          glow = [0.0, 1.0 - Math.sqrt(dx * dx + dy * dy) * 1.15].max
          red = 12 + (vertical * 88) + (glow * glow * 130)
          green = 3 + (vertical * 8) + (glow * glow * 26)
          blue = 3 + (vertical * 6) + (glow * glow * 10)
          row[x * 3] = red.round.clamp(0, 255)
          row[x * 3 + 1] = green.round.clamp(0, 255)
          row[x * 3 + 2] = blue.round.clamp(0, 255)
        end
        rows << row.pack('C*')
      end
      chunk = lambda do |type, body|
        [body.bytesize].pack('N') + type + body + [Zlib.crc32(type + body)].pack('N')
      end
      header = [size, size, 8, 2, 0, 0, 0].pack('NNCCCCC')
      "\x89PNG\r\n\x1a\n".b +
        chunk.call('IHDR', header) +
        chunk.call('IDAT', Zlib::Deflate.deflate(rows, Zlib::BEST_COMPRESSION)) +
        chunk.call('IEND', ''.b)
    end
  end

  # Minimal XML plist serializer (String/Integer/Float/true/false/Array/Hash) so the
  # Info.plist is exact and plutil-clean without depending on the gem's plist writer.
  module PlistXML
    module_function

    def render(value, depth)
      pad = '  ' * depth
      case value
      when Hash
        return "#{pad}<dict/>" if value.empty?

        lines = value.keys.sort.map do |key|
          "#{pad}  <key>#{escape(key)}</key>\n#{render(value[key], depth + 1)}"
        end
        "#{pad}<dict>\n#{lines.join("\n")}\n#{pad}</dict>"
      when Array
        return "#{pad}<array/>" if value.empty?

        "#{pad}<array>\n#{value.map { |item| render(item, depth + 1) }.join("\n")}\n#{pad}</array>"
      when TrueClass then "#{pad}<true/>"
      when FalseClass then "#{pad}<false/>"
      when Integer then "#{pad}<integer>#{value}</integer>"
      when Float then "#{pad}<real>#{value}</real>"
      when String then "#{pad}<string>#{escape(value)}</string>"
      else raise ArgumentError, "unsupported plist value #{value.class}"
      end
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end

  # ---------------------------------------------------------------------------
  # Project builder
  # ---------------------------------------------------------------------------

  class ProjectBuilder
    include Xcodeproj::Project::Object

    attr_reader :project, :target, :tree

    def initialize(project_path, tree)
      @project_path = Pathname.new(project_path)
      @tree = tree
      @groups = {}
    end

    def build
      @project = Xcodeproj::Project.new(@project_path, false, OBJECT_VERSION)
      configure_root_object
      apply_project_settings
      create_target
      add_sources
      add_shader_headers
      add_resources
      add_unbuilt_project_files
      add_frameworks
      add_local_package
      sort_source_groups
      order_main_group
      stamp_target_attributes
      finalize_uuids
      project
    end

    def save
      project.save(@project_path)
      # The gem writes through a private temp file; give it ordinary source-file permissions.
      File.chmod(0o644, @project_path + 'project.pbxproj')
      write_workspace_files
    end

    def write_workspace_files
      workspace = @project_path + 'project.xcworkspace'
      FileUtils.mkdir_p(workspace + 'xcshareddata')
      File.write(workspace + 'contents.xcworkspacedata', <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
           <FileRef
              location = "self:">
           </FileRef>
        </Workspace>
      XML
      File.write(workspace + 'xcshareddata' + 'IDEWorkspaceChecks.plist', <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>IDEDidComputeMac32BitWarning</key>
          <true/>
        </dict>
        </plist>
      XML
    end

    private

    def configure_root_object
      root = project.root_object
      root.development_region = 'en'
      root.known_regions = %w[en Base]
      root.project_dir_path = ''
      root.project_root = ''
      # Xcode 16-only attributes; leaving them out keeps the file readable by Xcode 15 as well.
      root.preferred_project_object_version = nil
      root.minimized_project_reference_proxies = nil
      root.attributes = {
        'BuildIndependentTargetsInParallel' => 'YES',
        'LastSwiftUpdateCheck' => XCODE_VERSION_STAMP,
        'LastUpgradeCheck' => XCODE_VERSION_STAMP,
      }
    end

    def apply_project_settings
      project.build_configurations.each do |config|
        config.build_settings = merged_settings(PROJECT_SETTINGS, config.name)
      end
    end

    def merged_settings(table, config_name)
      per_config = config_name == 'Debug' ? table[:debug] : table[:release]
      settings = table[:all].merge(per_config)
      settings.sort.to_h
    end

    def create_target
      @target = project.new(PBXNativeTarget)
      project.targets << target
      target.name = APP_NAME
      target.product_name = APP_NAME
      target.product_type = Xcodeproj::Constants::PRODUCT_TYPE_UTI[:application]

      config_list = project.new(XCConfigurationList)
      config_list.default_configuration_is_visible = '0'
      config_list.default_configuration_name = 'Release'
      %w[Debug Release].each do |name|
        config = project.new(XCBuildConfiguration)
        config.name = name
        config.build_settings = merged_settings(TARGET_SETTINGS, name)
        config_list.build_configurations << config
      end
      target.build_configuration_list = config_list

      target.product_reference = project.products_group.new_product_ref_for_target(APP_NAME, :application)
      [PBXSourcesBuildPhase, PBXFrameworksBuildPhase, PBXResourcesBuildPhase].each do |phase_class|
        target.build_phases << project.new(phase_class)
      end
    end

    # --- groups & file references ------------------------------------------------

    def app_group
      @groups[''] ||= project.main_group.new_group(APP_NAME, APP_NAME).tap { |group| group.name = nil }
    end

    # Group mirroring a directory relative to BornlessRitual/ (created on demand).
    def group_for(relative_dir)
      key = relative_dir.to_s
      return app_group if key.empty? || key == '.'

      @groups[key] ||= begin
        parent = group_for(relative_dir.dirname)
        component = relative_dir.basename.to_s
        parent.new_group(component, component).tap { |group| group.name = nil }
      end
    end

    def add_file_reference(relative_path)
      relative_path = Pathname.new(relative_path)
      group = group_for(relative_path.dirname)
      ref = group.new_reference(relative_path.basename.to_s)
      ref.include_in_index = nil
      ref.last_known_file_type ||= EXTRA_FILE_TYPES[relative_path.extname.downcase]
      ref
    end

    def add_sources
      (tree.swift + tree.metal).sort.each do |path|
        target.source_build_phase.add_file_reference(add_file_reference(path))
      end
    end

    # Shader headers are referenced for navigation only: found through
    # MTL_HEADER_SEARCH_PATHS / HEADER_SEARCH_PATHS and the bridging header,
    # never copied into the bundle, so they belong to no build phase.
    def add_shader_headers
      tree.shader_headers.each { |path| add_file_reference(path) }
    end

    def add_resources
      tree.resources.each do |path|
        target.resources_build_phase.add_file_reference(add_file_reference(path))
      end
    end

    # Info.plist and the bridging header are consumed through build settings, not phases.
    def add_unbuilt_project_files
      add_file_reference('Info.plist')
      add_file_reference("#{APP_NAME}-Bridging-Header.h")
    end

    # --- frameworks & package ------------------------------------------------------

    def add_frameworks
      frameworks_group = project.frameworks_group
      SDK_FRAMEWORKS.each do |name|
        ref = frameworks_group.new_reference("System/Library/Frameworks/#{name}.framework", :sdk_root)
        ref.name = "#{name}.framework"
        target.frameworks_build_phase.add_file_reference(ref)
      end
    end

    def add_local_package
      package_ref = project.new(XCLocalSwiftPackageReference)
      package_ref.relative_path = PACKAGE_RELATIVE_PATH
      project.root_object.package_references << package_ref

      dependency = project.new(XCSwiftPackageProductDependency)
      dependency.package = package_ref
      dependency.product_name = PACKAGE_PRODUCT
      target.package_product_dependencies << dependency

      build_file = project.new(PBXBuildFile)
      build_file.product_ref = dependency
      # Package products link first, then the SDK frameworks (mirrors Xcode's ordering).
      target.frameworks_build_phase.files.insert(0, build_file)

      # Navigator entry (what Xcode itself creates when a local package is added):
      # a wrapper folder reference in a "Packages" group.
      packages_group = project.main_group.new_group('Packages', 'Packages').tap { |group| group.name = nil }
      folder_ref = packages_group.new_reference(File.basename(PACKAGE_RELATIVE_PATH))
      folder_ref.last_known_file_type = 'wrapper'
      folder_ref.include_in_index = nil
    end

    # --- ordering ----------------------------------------------------------------

    # Groups above files, both alphabetical (case-insensitive), the way Xcode sorts.
    def sort_source_groups
      sort_group_recursively(app_group)
      project.frameworks_group.children.sort_by! { |child| child.display_name.downcase }
    end

    def sort_group_recursively(group)
      group.children.sort_by! do |child|
        [child.isa == 'PBXGroup' ? 0 : 1, child.display_name.downcase, child.display_name]
      end
      group.children.each { |child| sort_group_recursively(child) if child.isa == 'PBXGroup' }
    end

    def order_main_group
      wanted = [APP_NAME, 'Packages', 'Frameworks', 'Products']
      project.main_group.children.sort_by! { |child| wanted.index(child.display_name) || wanted.size }
    end

    def stamp_target_attributes
      project.root_object.attributes['TargetAttributes'] = {
        target.uuid => { 'CreatedOnToolsVersion' => TOOLS_VERSION_STAMP },
      }
    end

    # Replace random UUIDs with MD5s of each object's path in the object graph so
    # the output is stable across runs; fail loudly if two objects collide.
    def finalize_uuids
      count_before = project.objects.size
      project.predictabilize_uuids
      count_after = project.objects.size
      return if count_before == count_after

      raise "predictabilize_uuids dropped #{count_before - count_after} object(s) (duplicate paths)"
    end
  end

  # ---------------------------------------------------------------------------
  # Shared scheme
  # ---------------------------------------------------------------------------

  module SchemeBuilder
    module_function

    def build(target)
      scheme = Xcodeproj::XCScheme.new
      scheme.configure_with_targets(target, nil, launch_target: true)
      scheme.build_action.parallelize_buildables = true
      scheme.build_action.build_implicit_dependencies = true
      scheme.test_action.build_configuration = 'Debug'
      scheme.launch_action.build_configuration = 'Debug'
      scheme.profile_action.build_configuration = 'Release'
      scheme.analyze_action.build_configuration = 'Debug'
      scheme.archive_action.build_configuration = 'Release'
      scheme.archive_action.reveal_archive_in_organizer = true

      launch = scheme.launch_action
      launch.command_line_arguments = Xcodeproj::XCScheme::CommandLineArguments.new(
        [{ argument: LAUNCH_ARGUMENT_EXAMPLE, enabled: false }],
      )
      launch.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new(
        [{ key: 'MTL_DEBUG_LAYER', value: '0', enabled: true }],
      )
      scheme
    end

    def save(scheme, project_path)
      scheme.save_as(project_path.to_s, APP_NAME, true)
      project_path + 'xcshareddata' + 'xcschemes' + "#{APP_NAME}.xcscheme"
    end
  end

  # ---------------------------------------------------------------------------
  # Validation (re-open what was written and check the contract)
  # ---------------------------------------------------------------------------

  module Validator
    module_function

    def run(project_path, log: method(:puts))
      failures = []
      reopened = Xcodeproj::Project.open(project_path.to_s)
      target = reopened.targets.find { |candidate| candidate.name == APP_NAME }
      failures << "target #{APP_NAME} missing" unless target

      if target
        sources = build_phase_names(target.source_build_phase)
        resources = build_phase_names(target.resources_build_phase)
        frameworks = build_phase_names(target.frameworks_build_phase)
        packages = reopened.root_object.package_references.map(&:display_name)
        products = target.package_product_dependencies.map(&:product_name)

        failures << 'Info.plist must not be in a build phase' if (sources + resources).include?('Info.plist')
        failures << 'bridging header must not be in a build phase' if (sources + resources).any? { |name| name.end_with?('Bridging-Header.h') }
        failures << 'no .h may be compiled' if sources.any? { |name| name.end_with?('.h') }
        failures << 'local package reference missing' unless packages.include?(PACKAGE_RELATIVE_PATH)
        failures << "product dependency #{PACKAGE_PRODUCT} missing" unless products.include?(PACKAGE_PRODUCT)
        failures << "#{PACKAGE_PRODUCT} not linked in Frameworks phase" unless frameworks.include?(PACKAGE_PRODUCT)
        SDK_FRAMEWORKS.each do |name|
          failures << "#{name}.framework not linked" unless frameworks.include?("#{name}.framework")
        end
        %w[Debug Release].each do |config|
          settings = target.build_settings(config)
          failures << "#{config}: INFOPLIST_FILE wrong" unless settings['INFOPLIST_FILE'] == INFO_PLIST
          failures << "#{config}: bridging header wrong" unless settings['SWIFT_OBJC_BRIDGING_HEADER'] == BRIDGING_HEADER
          failures << "#{config}: TARGETED_DEVICE_FAMILY must be 1" unless settings['TARGETED_DEVICE_FAMILY'] == '1'
        end

        log.call("  target #{target.name} (#{target.product_type})")
        log.call("    sources   : #{sources.size} (#{sources.count { |name| name.end_with?('.swift') }} swift, #{sources.count { |name| name.end_with?('.metal') }} metal)")
        log.call("    resources : #{resources.size} #{resources.inspect}")
        log.call("    frameworks: #{frameworks.inspect}")
        log.call("    packages  : #{packages.inspect} -> products #{products.inspect}")
        log.call('  navigator:')
        print_tree(reopened.main_group, '    ', log)
      end

      failures.concat(validate_info_plist(APP_DIR + 'Info.plist', log))
      failures.concat(validate_scheme(project_path + 'xcshareddata' + 'xcschemes' + "#{APP_NAME}.xcscheme", log))
      failures
    end

    def build_phase_names(phase)
      phase.files.map do |build_file|
        build_file.product_ref ? build_file.product_ref.product_name : build_file.file_ref.display_name
      end
    end

    def print_tree(group, indent, log)
      group.children.each do |child|
        if child.isa == 'PBXGroup'
          log.call("#{indent}#{child.display_name}/")
          print_tree(child, indent + '  ', log)
        else
          log.call("#{indent}#{child.display_name}")
        end
      end
    end

    # plutil-equivalent: parse with python3's plistlib and assert the required keys.
    # Falls back to an REXML well-formedness check when python3 is unavailable.
    def validate_info_plist(path, log)
      required = %w[
        CFBundleIdentifier CFBundleName CFBundleDisplayName CFBundleShortVersionString CFBundleVersion
        CFBundlePackageType LSRequiresIPhoneOS UILaunchScreen UISupportedInterfaceOrientations
        UIApplicationSceneManifest UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace UIRequiredDeviceCapabilities
      ]
      python = python3_path
      unless python
        log.call('  Info.plist: python3 not found, XML well-formedness check only')
        REXML::Document.new(File.read(path))
        return []
      end

      script = <<~PY
        import json, plistlib, sys
        with open(sys.argv[1], 'rb') as fh:
            plist = plistlib.load(fh)
        missing = [k for k in sys.argv[2:] if k not in plist]
        problems = []
        if plist.get('UILaunchScreen') != {}: problems.append('UILaunchScreen must be an empty dict')
        if plist.get('UIApplicationSceneManifest', {}).get('UIApplicationSupportsMultipleScenes') is not False: problems.append('UIApplicationSupportsMultipleScenes must be false')
        if plist.get('CFBundlePackageType') != 'APPL': problems.append('CFBundlePackageType must be APPL')
        print(json.dumps({'missing': missing, 'problems': problems, 'keys': len(plist)}))
      PY
      output = IO.popen([python, '-c', script, path.to_s, *required], &:read)
      raise "python3 plistlib validation failed for #{path}" unless $?.success?

      result = JSON.parse(output)
      log.call("  Info.plist: #{result['keys']} keys, plistlib OK")
      result['missing'].map { |key| "Info.plist missing #{key}" } + result['problems']
    end

    def python3_path
      ENV['PATH'].split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'python3') }.find { |candidate| File.executable?(candidate) }
    end

    def validate_scheme(path, log)
      return ["scheme missing at #{path}"] unless path.exist?

      failures = []
      doc = REXML::Document.new(File.read(path))
      launch = doc.elements['Scheme/LaunchAction']
      failures << 'scheme has no LaunchAction' unless launch
      if launch
        args = launch.get_elements('CommandLineArguments/CommandLineArgument')
        env = launch.get_elements('EnvironmentVariables/EnvironmentVariable')
        failures << 'launch argument example missing' unless args.any? { |node| node.attributes['argument'] == LAUNCH_ARGUMENT_EXAMPLE && node.attributes['isEnabled'] == 'NO' }
        failures << 'MTL_DEBUG_LAYER env var missing' unless env.any? { |node| node.attributes['key'] == 'MTL_DEBUG_LAYER' && node.attributes['value'] == '0' }
        failures << 'launch action must build Debug' unless launch.attributes['buildConfiguration'] == 'Debug'
        runnable = launch.elements['BuildableProductRunnable/BuildableReference']
        failures << 'launch runnable missing' unless runnable && runnable.attributes['BlueprintName'] == APP_NAME
        log.call("  scheme: #{path.basename} launch=#{launch.attributes['buildConfiguration']} args=#{args.size} env=#{env.size}")
      end
      failures
    end
  end

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  module CLI
    module_function

    def parse(argv)
      options = { check: false, force_scaffold: false, quiet: false }
      OptionParser.new do |parser|
        parser.banner = 'Usage: ruby Tools/gen_xcodeproj.rb [--check] [--force-scaffold] [--quiet]'
        parser.on('--check', 'Generate into a temp dir and fail if it differs from the committed project') { options[:check] = true }
        parser.on('--force-scaffold', 'Rewrite Info.plist, bridging header and asset catalog stubs') { options[:force_scaffold] = true }
        parser.on('--quiet', 'Only print failures') { options[:quiet] = true }
      end.parse!(argv)
      options
    end

    def run(argv)
      options = parse(argv)
      log = options[:quiet] ? ->(_line) {} : method(:puts)

      log.call("gen_xcodeproj: repo #{ROOT}")
      log.call("  xcodeproj gem #{Xcodeproj::VERSION}, object version #{OBJECT_VERSION}")
      # --check must not touch the tree; scaffolding only happens on a real generate.
      Scaffold.run(force: options[:force_scaffold], log: log) unless options[:check]

      tree = Scanner.scan
      log.call("  scan: #{tree.swift.size} swift, #{tree.metal.size} metal, #{tree.shader_headers.size} shader headers, #{tree.resources.size} resources")
      tree.skipped.each { |path| warn "  warning: unrecognised resource skipped: #{path}" }

      return check(tree, log) if options[:check]

      generate(PROJECT_PATH, tree)
      log.call("  wrote #{PROJECT_PATH.relative_path_from(ROOT)}/project.pbxproj")
      failures = Validator.run(PROJECT_PATH, log: log)
      report(failures)
    end

    def generate(project_path, tree)
      builder = ProjectBuilder.new(project_path, tree)
      builder.build
      builder.save
      scheme = SchemeBuilder.build(builder.target)
      SchemeBuilder.save(scheme, project_path)
      builder
    end

    # Generates into a temp dir with the same basename (UUIDs derive from the basename
    # only) and compares the tracked outputs byte for byte.
    def check(tree, log)
      Dir.mktmpdir('gen_xcodeproj') do |tmp|
        candidate = Pathname.new(tmp) + PROJECT_PATH.basename
        generate(candidate, tree)
        differences = generated_files(candidate).reject do |relative|
          committed = PROJECT_PATH + relative
          committed.exist? && File.binread(committed) == File.binread(candidate + relative)
        end
        if differences.empty?
          log.call('  check: committed project is up to date')
          return 0
        end
        differences.each { |relative| warn "  stale: #{PROJECT_PATH.basename}/#{relative}" }
        warn 'gen_xcodeproj --check FAILED: run `ruby Tools/gen_xcodeproj.rb` and commit the result'
        1
      end
    end

    def generated_files(project_path)
      Dir.glob('**/*', base: project_path.to_s, flags: File::FNM_DOTMATCH)
         .reject { |relative| File.directory?(project_path + relative) }
         .sort
    end

    def report(failures)
      if failures.empty?
        puts 'gen_xcodeproj: OK'
        0
      else
        failures.each { |failure| warn "  FAIL: #{failure}" }
        warn 'gen_xcodeproj: validation FAILED'
        1
      end
    end
  end
end

exit(GenXcodeproj::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
