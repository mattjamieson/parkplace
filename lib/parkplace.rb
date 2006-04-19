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

module ParkPlace
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
            Camping::Models::Session.create_schema
            ParkPlace::Models.create_schema
        end
        def serve
            require 'mongrel'
            require 'mongrel/camping'

            ParkPlace::Models::Base.establish_connection :adapter => 'sqlite3', :database => 'park.db'
            ParkPlace::Models::Base.logger = Logger.new('camping.log') if $DEBUG
            ParkPlace::Models::Base.threaded_connections=false
            ParkPlace.create

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

if __FILE__ == $0
    require 'parkplace/control'
    ParkPlace.serve
end
