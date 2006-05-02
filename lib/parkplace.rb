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
require 'parkplace/controllers'
require 'parkplace/models'
begin
    require 'parkplace/torrent'
    puts "-- RubyTorrent found, torrent support is turned on."
    puts "-- TORRENT SUPPORT IS EXTREMELY EXPERIMENTAL -- WHAT I MEAN IS: IT PROBABLY DOESN'T WORK."
rescue LoadError
    puts "-- No RubyTorrent found, torrent support disbled."
end

module ParkPlace
    VERSION = "1.0"
    BUFSIZE = (4 * 1024)
    STORAGE_PATH ||= File.join(Dir.pwd, 'storage')
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
            Camping::Models::Session.create_schema
            ParkPlace::Models.create_schema
        end
        def serve
            require 'mongrel'
            require 'mongrel/camping'

            # Use the Configurator as an example rather than Mongrel::Camping.start
            config = Mongrel::Configurator.new :host => "0.0.0.0" do
                listener :port => 3002 do
                    uri "/", :handler => Mongrel::Camping::CampingHandler.new(ParkPlace)
                    uri "/favicon", :handler => Mongrel::Error404Handler.new("")
                    trap("INT") { stop }
                    run
                end
            end

            puts "** ParkPlace example is running at http://localhost:3002/"
            config.join
        end
    end
end
