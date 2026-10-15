#!/usr/bin/env ruby
require 'open3'
require 'tempfile'

aar, readelf = ARGV
abort 'usage: verify-runtime-link.rb candidate.aar pinned-llvm-readelf' unless aar && readelf

def inspect_elf(readelf, option, file)
  output, error, status = Open3.capture3(readelf, option, '--wide', file.path)
  abort error unless status.success?
  output
end

def dynamic_symbols(output)
  output.lines.map(&:split).select do |fields|
    fields.length >= 8 && %w[GLOBAL WEAK].include?(fields[4])
  end
end

%w[arm64-v8a armeabi-v7a x86 x86_64].each do |abi|
  Tempfile.create(['released-runtime', '.so']) do |runtime|
    Tempfile.create(['rebuilt-player', '.so']) do |player|
      { 'libc++_shared.so' => runtime, 'libplayer.so' => player }.each do |name, file|
        abort "cannot extract #{abi}/#{name}" unless system('unzip', '-p', aar, "jni/#{abi}/#{name}", out: file)
        file.flush
      end
      dynamic = inspect_elf(readelf, '--dynamic', player)
      abort "#{abi}: missing shared C++ runtime dependency" unless dynamic.include?('Shared library: [libc++_shared.so]')
      exports = dynamic_symbols(inspect_elf(readelf, '--dyn-syms', runtime)).select do |fields|
        fields[6] != 'UND' && %w[DEFAULT PROTECTED].include?(fields[5])
      end.map { |fields| fields[7] }
      requirements = dynamic_symbols(inspect_elf(readelf, '--dyn-syms', player)).select do |fields|
        fields[6] == 'UND' && fields[7].match?(/\A(?:_Z|__cxa|__gxx|_Unwind)/) &&
          !fields[7].match?(/@LIBC(?:_|\z)/)
      end
      abort "#{abi}: expected the binding's C++ dynamic requirements" if requirements.empty?
      missing = requirements.reject do |fields|
        name, version = fields[7].split('@', 2)
        exports.any? do |symbol|
          exported_name, exported_version = symbol.split(/@@?/, 2)
          exported_name == name && (version ? exported_version == version :
            exported_version.nil? || symbol.include?('@@'))
        end
      end
      required_missing = missing.select { |fields| fields[4] == 'GLOBAL' }
      abort "#{abi}: released runtime lacks #{required_missing.map { |fields| fields[7] }.join(', ')}" unless required_missing.empty?
      puts "#{abi}: #{requirements.length} C++ dynamic requirements checked; optional unresolved weak symbols: #{missing.map { |fields| fields[7] }.join(', ')}"
    end
  end
end
puts 'C++ symbol/version coverage checked; this is not playback/runtime proof'
