module ParkPlace
    module Models

        class FileInfo
            attr_accessor :path, :mime_type, :disposition, :size, :md5
        end

        class User < Base
            has_many :bits, :foreign_key => 'owner_id'
            validates_length_of :login, :within => 3..40
            validates_uniqueness_of :login
            validates_uniqueness_of :key
            validates_confirmation_of :password
            def before_save
                @password_clean = self.password
                self.password = hmac_sha1(self.password, self.secret)
            end
            def after_save
                self.password = @password_clean
            end
        end

        class Bit < Base
            acts_as_nested_set
            serialize :meta
            serialize :obj
            belongs_to :owner, :class_name => 'User', :foreign_key => 'owner_id'
            has_and_belongs_to_many :users
            has_one :torrent
            validates_length_of :name, :within => 3..255

            def fullpath; File.join(STORAGE_PATH, name) end
            def grant hsh
                if hsh[:access]
                    self.access = hsh[:access]
                    self.save
                end
            end
            def access_readable
                name, _ = CANNED_ACLS.find { |k, v| v == self.access }
                if name
                    name
                else
                    [0100, 0010, 0001].map do |i|
                        [[4, 'r'], [2, 'w'], [1, 'x']].map do |k, v|
                            (self.access & (i * k) == 0 ? '-' : v )
                        end
                    end.join
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
            def fullpath; File.join(STORAGE_PATH, obj.path) end
            def etag
                if self.obj.respond_to? :md5
                    self.obj.md5
                else
                   %{"#{MD5.md5(self.obj)}"}
                end
            end
        end

        class Torrent < Base
            belongs_to :bit
            has_many :torrent_peers
        end

        class TorrentPeer < Base
            belongs_to :torrent
        end

        def self.create_schema
            unless Torrent.table_exists?
                ActiveRecord::Schema.define do
                    create_table :parkplace_torrents do |t|
                        t.column :id,        :integer,  :null => false
                        t.column :bit_id,    :integer
                        t.column :info_hash, :string,   :limit => 40
                        t.column :metainfo,  :binary
                        t.column :seeders,   :integer,  :null => false, :default => 0
                        t.column :leechers,  :integer,  :null => false, :default => 0
                        t.column :hits,      :integer,  :null => false, :default => 0
                        t.column :total,     :integer,  :null => false, :default => 0
                        t.column :updated_at, :timestamp
                    end
                    create_table :parkplace_torrent_peers do |t|
                        t.column :id,         :integer,  :null => false
                        t.column :torrent_id, :integer
                        t.column :guid,       :string,   :limit => 40
                        t.column :ipaddr,     :string
                        t.column :port,       :integer
                        t.column :uploaded,   :integer,  :null => false, :default => 0
                        t.column :downloaded, :integer,  :null => false, :default => 0
                        t.column :remaining,  :integer,  :null => false, :default => 0
                        t.column :compact,    :integer,  :null => false, :default => 0
                        t.column :event,      :integer,  :null => false, :default => 0
                        t.column :key,        :string,   :limit => 55
                        t.column :created_at, :timestamp
                        t.column :updated_at, :timestamp
                    end
                end
            end
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
                        t.column :obj,       :text
                    end
                    create_table :parkplace_users do |t|
                        t.column :id,             :integer,  :null => false
                        t.column :login,          :string,   :limit => 40
                        t.column :password,       :string,   :limit => 40
                        t.column :email,          :string,   :limit => 64
                        t.column :key,            :string,   :limit => 64
                        t.column :secret,         :string,   :limit => 64
                        t.column :created_at,     :datetime
                        t.column :activated_at,   :datetime
                        t.column :superuser,      :integer, :default => 0
                        t.column :deleted,        :integer, :default => 0
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
end
