require 'rake'
require 'rake/clean'
require 'rake/gempackagetask'
require 'rake/rdoctask'
require 'fileutils'
include FileUtils

NAME = "parkplace"
VERSION = "1.0"
CLEAN.include ['**/.*.sw?', '*.gem', '.config']

Rake::RDocTask.new do |rdoc|
    rdoc.rdoc_dir = 'doc/rdoc'
    rdoc.options << '--line-numbers'
    rdoc.rdoc_files.add ['README', 'COPYING', 'lib/**/*.rb', 'doc/**/*.rdoc']
end

desc "Packages up Park Place."
task :default => [:package]
task :package => [:clean]

spec =
    Gem::Specification.new do |s|
        s.name = NAME
        s.version = VERSION
        s.platform = Gem::Platform::RUBY
        s.has_rdoc = true
        s.extra_rdoc_files = [ "README" ]
        s.summary = "a web file storage service, lovely with BitTorrent support."
        s.description = s.summary
        s.author = "why the lucky stiff"
        s.executables = ['parkplace']

        s.add_dependency('mongrel', '>= 0.3.12.5')
        s.add_dependency('camping', '>= 1.4.1')
        s.add_dependency('rubytorrent', '>= 0.3')
        s.required_ruby_version = '>= 1.8.4'

        s.files = %w(COPYING README Rakefile) +
          Dir.glob("{bin,doc/rdoc,test,lib}/**/*") + 
          Dir.glob("ext/**/*.{h,c,rb}") +
          Dir.glob("examples/**/*.rb") +
          Dir.glob("tools/*.rb")
        
        s.require_path = "lib"
        # s.extensions = FileList["ext/**/extconf.rb"].to_a
        s.bindir = "bin"
    end

Rake::GemPackageTask.new(spec) do |p|
    p.need_tar = true
    p.gem_spec = spec
end

task :install do
  sh %{rake package}
  sh %{sudo gem install pkg/#{NAME}-#{VERSION}}
end

task :uninstall => [:clean] do
  sh %{sudo gem uninstall mongrel}
end
