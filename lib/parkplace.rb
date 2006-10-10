require 'rubygems'
require 'camping'
require 'camping/session'
require 'digest/sha1'
require 'base64'
require 'time'
require 'md5'

Camping.goes :ParkPlace

require 'parkplace/errors'
require 'parkplace/helpers'
require 'parkplace/models'
require 'parkplace/controllers'
if $PARKPLACE_ACCESSORIES
  require 'parkplace/control'
end
begin
    require 'parkplace/torrent'
    puts "-- RubyTorrent found, torrent support is turned on."
    puts "-- TORRENT SUPPORT IS EXTREMELY EXPERIMENTAL -- WHAT I MEAN IS: IT PROBABLY DOESN'T WORK."
rescue LoadError
    puts "-- No RubyTorrent found, torrent support disbled."
end
require 'parkplace/s3'

module ParkPlace
    VERSION = "0.7"
    BUFSIZE = (4 * 1024)
    STORAGE_PATH = File.join(Dir.pwd, 'storage')
    STATIC_PATH = File.expand_path('../static', File.dirname(__FILE__))
    RESOURCE_TYPES = %w[acl torrent]
    CANNED_ACLS = {
        'private' => 0600,
        'public-read' => 0644,
        'public-read-write' => 0666,
        'authenticated-read' => 0640,
        'authenticated-read-write' => 0660
    }
    READABLE = 0004
    WRITABLE = 0002
    READABLE_BY_AUTH = 0040
    WRITABLE_BY_AUTH = 0020

    class << self
        def create
            v = 0.0
            v = 1.0 if Models::Bucket.table_exists?
            Camping::Models::Session.create_schema
            Models.create_schema :assume => v
        end
        def options
            require 'ostruct'
            options = OpenStruct.new
            if options.parkplace_dir.nil?
                homes = []
                homes << [ENV['HOME'], File.join( ENV['HOME'], '.parkplace' )] if ENV['HOME']
                homes << [ENV['APPDATA'], File.join( ENV['APPDATA'], 'ParkPlace' )] if ENV['APPDATA']
                homes.each do |home_top, home_dir|
                    next unless home_top
                    if File.exists? home_top
                        options.parkplace_dir = home_dir
                        break
                    end
                end
            end
            options
        end
        def config(options)
            require 'ftools'
            require 'yaml'
            abort "** No home directory found, please say the directory when you run #$O." unless options.parkplace_dir
            File.makedirs( options.parkplace_dir )
            conf = File.join( options.parkplace_dir, 'config.yaml' )
            if File.exists? conf
                YAML.load_file( conf ).each { |k,v| options.__send__("#{k}=", v) if options.__send__(k).nil? }
            end
            options.storage_dir = File.expand_path(options.storage_dir || 'storage', options.parkplace_dir)
            options.database ||= {:adapter => 'sqlite3', :database => File.join(options.parkplace_dir, 'park.db')}
            if options.database[:adapter] == 'sqlite3'
                begin
                    require 'sqlite3_api'
                rescue LoadError
                    puts "!! Your SQLite3 adapter isn't a compiled extension."
                    abort "!! Please check out http://code.whytheluckystiff.net/camping/wiki/BeAlertWhenOnSqlite3 for tips."
                end
            end
            ParkPlace::STORAGE_PATH.replace options.storage_dir
        end
        def serve(host, port)
            require 'mongrel'
            require 'mongrel/camping'
            if $PARKPLACE_PROGRESS
              require_gem 'mongrel_upload_progress'
              GemPlugin::Manager.instance.load "mongrel" => GemPlugin::INCLUDE
            end

            config = Mongrel::Configurator.new :host => host do
                listener :port => port do
                    uri "/", :handler => Mongrel::Camping::CampingHandler.new(ParkPlace)
                    if $PARKPLACE_PROGRESS
                      uri "/control/buckets", :handler => plugin('/handlers/upload')
                    end
                    uri "/favicon", :handler => Mongrel::Error404Handler.new("")
                    trap("INT") { stop }
                    run
                end
            end

            puts "** ParkPlace example is running at http://#{host}:#{port}/"
            puts "** Visit http://#{host}:#{port}/control/ for the control center."
            config.join
        end
    end
end
