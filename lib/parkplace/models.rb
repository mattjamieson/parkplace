module ParkPlace
    module Models

        class FileInfo
            attr_accessor :path, :mime_type, :disposition, :size, :md5
        end

        class User < Base
            has_many :bits, :foreign_key => 'owner_id'
            validates_uniqueness_of :key
        end

        class Bit < Base
            acts_as_nested_set
            serialize :meta
            serialize :obj
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
           def etag
               if self.obj.respond_to? :md5
                   self.obj.md5
               else
                  %{"#{MD5.md5(self.obj)}"}
               end
           end
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
