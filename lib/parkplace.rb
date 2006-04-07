require 'rubygems'
require 'camping'
require 'digest/sha1'
require 'base64'
require 'time'
require 'md5'

Camping.goes :ParkPlace

module ParkPlace
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

    class ServiceError < Exception; end
    YAML::load(<<-END).
        AccessDenied: [403, Access Denied]
        AllAccessDisabled: [401, All access to this object has been disabled.]
        AmbiguousGrantByEmailAddress: [400, The e-mail address you provided is associated with more than one account.]
        BadAuthentication: [401, The authorization information you provided is invalid. Please try again.]
        BadDigest: [400, The Content-MD5 you specified did not match what we received.]
        BucketAlreadyExists: [409, The named bucket you tried to create already exists.]
        BucketNotEmpty: [409, The bucket you tried to delete is not empty.]
        CredentialsNotSupported: [400, This request does not support credentials.]
        EntityTooLarge: [400, Your proposed upload exceeds the maximum allowed object size.]
        IncompleteBody: [400, You did not provide the number of bytes specified by the Content-Length HTTP header.]
        InternalError: [500, We encountered an internal error. Please try again.]
        InvalidArgument: [400, Invalid Argument]
        InvalidBucketName: [400, The specified bucket is not valid.]
        InvalidDigest: [400, The Content-MD5 you specified was an invalid.]
        InvalidRange: [416, The requested range is not satisfiable.]
        InvalidSecurity: [403, The provided security credentials are not valid.]
        InvalidSOAPRequest: [400, The SOAP request body is invalid.]
        InvalidStorageClass: [400, The storage class you specified is not valid.]
        InvalidURI: [400, Couldn't parse the specified URI.]
        MalformedACLError: [400, The XML you provided was not well-formed or did not validate against our published schema.]
        MethodNotAllowed: [405, The specified method is not allowed against this resource.]
        MissingContentLength: [411, You must provide the Content-Length HTTP header.]
        MissingSecurityElement: [400, The SOAP 1.1 request is missing a security element.]
        MissingSecurityHeader: [400, Your request was missing a required header.]
        NoSuchBucket: [404, The specified bucket does not exist.]
        NoSuchKey: [404, The specified key does not exist.]
        NotImplemented: [501, A header you provided implies functionality that is not implemented.]
        PreconditionFailed: [412, At least one of the pre-conditions you specified did not hold.]
        RequestTimeout: [400, Your socket connection to the server was not read from or written to within the timeout period.]
        RequestTorrentOfBucketError: [400, Requesting the torrent file of a bucket is not permitted.]
        TooManyBuckets: [400, You have attempted to create more buckets than allowed.]
        UnexpectedContent: [400, This request does not support content.]
        UnresolvableGrantByEmailAddress: [400, The e-mail address you provided does not match any account on record.]
    END
        each do |code, (status, msg)|
            const_set(code, Class.new(ServiceError) { 
                {:code=>code, :status=>status, :message=>msg}.each do |k,v|
                    define_method(k) { v }
                end
            })
        end

    def xml status = 200
        xml = Builder::XmlMarkup.new
        xml.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
        yield xml
        r(status, xml.target!, 'Content-Type' => 'application/xml')
    end

    def hmac_sha1(key, s)
        ipad = [].fill(0x36, 0, 64)
        opad = [].fill(0x5C, 0, 64)
        key = key.unpack("C*")
        if key.length < 64 then
        key += [].fill(0, 0, 64-key.length)
        end

        inner = []
        64.times { |i| inner.push(key[i] ^ ipad[i]) }
        inner += s.unpack("C*")

        outer = []
        64.times { |i| outer.push(key[i] ^ opad[i]) }
        outer = outer.pack("c*")
        outer += Digest::SHA1.digest(inner.pack("c*"))

        return Base64::encode64(Digest::SHA1.digest(outer)).chomp
    end

    def service(*a)
        @meta, @amz = H[], H[]
        @env.each do |k, v|
            k = k.downcase.gsub('_', '-')
            @amz[$1] = v.strip if k =~ /^http-x-amz-([-\w]+)$/
            @meta[$1] = v if k =~ /^http-x-amz-meta-([-\w]+)$/
        end

        auth, key_s, secret_s = *@env.HTTP_AUTHORIZATION.to_s.match(/^AWS (\w+):(.+)$/)
        date_s = @env.HTTP_X_AMZ_DATE || @env.HTTP_DATE
        if @input.Signature and Time.at(@input.Expires.to_i) >= Time.now
            key_s, secret_s, date_s = @input.AWSAccessKeyId, @input.Signature, @input.Expires
        end
        canonical = [@env.REQUEST_METHOD, @env.HTTP_CONTENT_MD5, @env.HTTP_CONTENT_TYPE, 
            date_s, @env.PATH_INFO]
        @amz.sort.each do |k, v|
            canonical[-1,0] = "x-amz-#{k}:#{v}"
        end
        @user = Models::User.find_by_key key_s
        if @user and secret_s != hmac_sha1(@user.secret, canonical * "\n")
            raise BadAuthentication
        end

        s = super(*a)
        s.headers['Server'] = 'ParkPlace'
        s
    rescue ServiceError => e
        xml e.status do |x|
            x.Error do
                x.Code e.code
                x.Message e.message
                x.Resource @env.PATH_INFO
                x.RequestId Time.now.to_i
            end
        end
        self
    end

    def only_authorized; raise AccessDenied unless @user end
    def only_can_read bit; raise AccessDenied unless bit.readable_by? @user end
    def only_can_write bit; raise AccessDenied unless bit.writable_by? @user end
    def only_owner_of bit; raise AccessDenied unless bit.owned_by? @user end

    def requested_acl
        # FIX: parse XML
        raise NotImplemented if @input.has_key? 'acl'
        {:access => CANNED_ACLS[@amz['acl']] || CANNED_ACLS['private']}
    end

    module Controllers
        class RService < R '/'
            def get
                only_authorized
                buckets = Bucket.find :all, :conditions => ['parent_id IS NULL AND owner_id = ?', @user.id], :order => "name"

                xml do |x|
                    x.ListAllMyBucketsResult :xmlns => "http://s3.amazonaws.com/doc/2006-03-01/" do
                        x.Owner do
                            x.ID @user.key
                            x.DisplayName @user.login
                        end
                        x.Buckets do
                            buckets.each do |b|
                                x.Bucket do
                                    x.Name b.name
                                    x.CreationDate b.created_at.iso8601
                                end
                            end
                        end
                    end
                end
            end
        end

        class RBucket < R '/([^\/]+)/?'
            def put(bucket_name)
                only_authorized
                Bucket.find_root(bucket_name).grant(requested_acl)
                raise BucketAlreadyExists
            rescue NoSuchBucket
                Bucket.create(:name => bucket_name, :owner_id => @user.id).grant(requested_acl)
                r(200, '', 'Location' => @env.PATH_INFO, 'Content-Length' => 0)
            end
            def delete(bucket_name)
                bucket = Bucket.find_root(bucket_name)
                only_owner_of bucket

                if Slot.count(:conditions => ['parent_id = ?', bucket.id]) > 0
                    raise BucketNotEmpty
                end
                bucket.destroy
                r(204, '')
            end
            def get(bucket_name)
                bucket = Bucket.find_root(bucket_name)
                only_can_read bucket

                opts = {:conditions => ['parent_id = ?', bucket.id], :order => "name"}
                limit = nil
                if @input.prefix
                    opts[:conditions].first << ' AND name LIKE ?'
                    opts[:conditions] << "#{@input.prefix}%"
                end
                if @input.marker
                    opts[:offset] = @input.marker.to_i
                end
                if @input['max-keys']
                    opts[:limit] = @input['max-keys'].to_i
                end
                slot_count = Slot.count :conditions => opts[:conditions]
                contents = Slot.find :all, opts

                xml do |x|
                    x.ListBucketResult :xmlns => "http://s3.amazonaws.com/doc/2006-03-01/" do
                        x.Name bucket.name
                        x.Prefix @input.prefix if @input.prefix
                        x.Marker @input.marker if @input.marker
                        x.MaxKeys @input['max-keys'] if @input['max-keys']
                        x.IsTruncated slot_count > contents.length + opts[:offset].to_i
                        contents.each do |c|
                            x.Contents do
                                x.Key c.name
                                x.LastModified c.updated_at.iso8601
                                x.ETag c.etag
                                x.Size c.obj.size
                                x.StorageClass "STANDARD"
                                x.Owner do
                                    x.ID c.owner.key
                                    x.DisplayName c.owner.login
                                end
                            end
                        end
                    end
                end
            end
        end

        class RSlot < R '/(.+?)/(.+)'
            def put(bucket_name, oid)
                bucket = Bucket.find_root bucket_name
                only_can_write bucket
                raise MissingContentLength unless @env.HTTP_CONTENT_LENGTH
                raise IncompleteBody if @env.HTTP_CONTENT_LENGTH.to_i > @in.size
                if @env.HTTP_CONTENT_MD5
                    raise InvalidDigest unless @env.HTTP_CONTENT_MD5 =~ /^[0-9a-fA-F]{32}$/
                    raise BadDigest unless MD5.md5(@in) == @env.HTTP_CONTENT_MD5
                end

                slot = nil
                meta = @meta.empty? ? nil : {}.merge(@meta)
                begin
                    slot = bucket.find_slot(oid)
                    slot.update_attributes(:owner_id => @user.id, :meta => meta, :obj => @in)
                rescue NoSuchKey
                    slot = Slot.create(:name => oid, :owner_id => @user.id, :meta => meta, :obj => @in)
                    bucket.add_child(slot)
                end
                slot.grant(requested_acl)
                r(200, '', 'ETag' => slot.etag, 'Content-Length' => 0)
            end
            def head(bucket_name, oid)
                @slot = Bucket.find_root(bucket_name).find_slot(oid)
                only_can_read @slot
                headers = {}
                if @slot.meta
                    headers = @slot.meta.inject({}) { |hsh, (k, v)| hsh["x-amz-meta-#{k}"] = v; hsh }
                end
                r(200, '', headers.merge('ETag' => @slot.etag, 'Content-Type' => 'text/plain',
                                         'Content-Length' => (@slot.obj || '').size))
            end
            def get(bucket_name, oid)
                head(bucket_name, oid)
                @slot.obj
            end
            def delete(bucket_name, oid)
                bucket = Bucket.find_root bucket_name
                only_can_write bucket
                @slot = bucket.find_slot(oid)
                @slot.destroy
                r(204, '')
            end
        end
    end

    module Models

        class User < Base
            has_many :bits, :foreign_key => 'owner_id'
            validates_uniqueness_of :key
        end

        class Bit < Base
            acts_as_nested_set
            serialize :meta
            belongs_to :owner, :class_name => 'User', :foreign_key => 'owner_id'
            has_and_belongs_to_many :users
            validates_length_of :name, :within => 3..255

            def grant hsh
                if hsh[:access]
                    self.access = hsh[:access]
                    self.save
                end
            end
            def check_access user, group_perm, user_perm
                !!( if owned_by?(user) or (user and access & group_perm > 0) or (access & user_perm > 0)
                        true
                    elsif user
                        acl = users.find(user.id) rescue nil
                        acl and acl.access.to_i & user_perm
                    end )
            end
            def owned_by? user
                user and owner_id == user.id
            end
            def readable_by? user
                check_access(user, READABLE_BY_AUTH, READABLE)
            end
            def writable_by? user
                check_access(user, WRITABLE_BY_AUTH, WRITABLE)
            end
        end

        class Bucket < Bit
            validates_format_of :name, :with => /^[-\w]+$/
            def self.find_root(bucket_name)
                find(:first, :conditions => ['parent_id IS NULL AND name = ?', bucket_name]) or raise NoSuchBucket
            end
            def find_slot(oid)
                Slot.find(:first, :conditions => ['parent_id = ? AND name = ?', self.id, oid]) or raise NoSuchKey
            end
        end

        class Slot < Bit
           def etag; %{"#{MD5.md5(self.obj)}"} end
        end

        def self.create_schema
            unless Bucket.table_exists?
                ActiveRecord::Schema.define do
                    create_table :parkplace_bits do |t|
                        t.column :id,        :integer,  :null => false
                        t.column :owner_id,  :integer
                        t.column :parent_id, :integer
                        t.column :lft,       :integer
                        t.column :rgt,       :integer
                        t.column :type,      :string,   :limit => 6
                        t.column :name,      :string,   :limit => 255
                        t.column :created_at, :timestamp
                        t.column :updated_at, :timestamp
                        t.column :access,    :integer
                        t.column :meta,      :text
                        t.column :obj,       :binary
                    end
                    create_table :parkplace_users do |t|
                        t.column :id,      :integer,  :null => false
                        t.column :login,   :string,   :limit => 40
                        t.column :key,     :string,   :limit => 64
                        t.column :secret,  :string,   :limit => 64
                    end
                    create_table :parkplace_bits_users do |t|
                        t.column :bit_id,  :integer
                        t.column :user_id, :integer
                        t.column :access,  :integer
                    end
                end
            end
        end
    end
    def self.create
        ParkPlace::Models.create_schema
    end
end

if __FILE__ == $0
    require 'mongrel'
    require 'mongrel/camping'

    ParkPlace::Models::Base.establish_connection :adapter => 'sqlite3', :database => 'park.db'
    ParkPlace::Models::Base.logger = Logger.new('camping.log')
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
