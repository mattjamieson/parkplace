require 'parkplace/mimetypes_hash'

class Class
    def login_required
        include Camping::Session, ParkPlace::UserSession
    end
end

module ParkPlace::UserSession
    def service(*a)
        if @state.user_id
            @user = ParkPlace::Models::User.find :first, @state.user_id
        end
        if @user
            super(*a)
        else
            redirect Controllers::CLogin
        end
        self
    end
end

module ParkPlace::Controllers
    class CHome < R '/control'
        login_required
        def get
            redirect CBuckets
        end
    end

    class CLogin < R '/control/login'
        include Camping::Session
        def get
            render :control, "Login", :login
        end
        def post
            user = User.find_by_login @input.login
            if user
                if user.password == hmac_sha1( @input.password, user.secret )
                    @user = user
                    @state.user_id = @user.id
                    return redirect(CBuckets)
                else
                    @user.errors.add(:password, 'is incorrect')
                end
            else
                @user.errors.add(:login, 'not found')
            end
            render :control, "Login", :login
        end
    end

    class CLogout < R '/control/logout'
        login_required
        def get
            @state.clear
            redirect CHome
        end
    end

    class CBuckets < R '/control/buckets'
        login_required
        def get
            @buckets = Bucket.find :all, :conditions => ['parent_id IS NULL AND owner_id = ?', @user.id], :order => "name"
            render :control, 'Your Buckets', :buckets
        end
        def post
            Bucket.find_root(@input.bname)
            redirect CBuckets
        rescue NoSuchBucket
            bucket = Bucket.create(:name => @input.bname, :owner_id => @user.id)
            bucket.grant(:access => @input.bacl.to_i)
            redirect CBuckets
        end
    end

    class CFiles < R '/control/buckets/(.+)'
        login_required
        def get(bucket_name)
            @bucket = Bucket.find_root(bucket_name)
            only_can_read @bucket
            @files = Slot.find :all, :conditions => ['parent_id = ?', @bucket.id], :order => 'name'
            render :control, "/#{@bucket.name}", :files
        end
        def post(bucket_name)
            bucket = Bucket.find_root(bucket_name)
            only_can_write bucket

            tmpf = @input.upfile.tempfile
            readlen, md5 = 0, MD5.new
            while part = tmpf.read(BUFSIZE)
                readlen += part.size
                md5 << part
            end
            fileinfo = FileInfo.new
            fileinfo.mime_type = @input.upfile['type'] || "binary/octet-stream"
            fileinfo.size = readlen
            fileinfo.md5 = md5.hexdigest

            bucket_dir = File.join(STORAGE_PATH, bucket_name)
            fileinfo.path = File.join(bucket_dir, File.basename(tmpf.path))
            FileUtils.mkdir_p(bucket_dir)
            FileUtils.mv(tmpf.path, fileinfo.path)

            @input.fname = @input.upfile.filename if @input.fname.blank?
            slot = Slot.create(:name => @input.fname, :owner_id => @user.id, :meta => nil, :obj => fileinfo)
            bucket.add_child(slot)
            slot.grant(:access => @input.bacl.to_i)
            redirect CFiles, bucket_name
        end
    end

    class CFile < R '/control/buckets/(.+)/(.+)'
        login_required
        include ParkPlace::SlotGet
    end

    class CUsers < R '/control/users'
        login_required
        def get
            @users = User.find :all, :conditions => ['deleted != 1']
            render :control, "User List", :users
        end
    end

    class CUser < R '/control/user/(.+)'
        login_required
        def get(login)
            @user = User.find_by_login login
            render :control, "Profile for #{@user.login}", :profile
        end
    end

    class CProfile < R '/control/profile'
        login_required
        def get
            render :control, "Your Profile", :profile
        end
    end

    class CStatic < R '/control/s/(.+)'
        def get(path)
            @headers['Content-Type'] = MIME_TYPES[path[/\.\w+$/, 0]] || "text/plain"
            @headers['X-Sendfile'] = File.join(ParkPlace::STATIC_PATH, path)
        end
    end
end

module ParkPlace::Views
    def control(str, view)
        html do
            head do
                title { "Park Place Control Center &raquo; " + str }
                script :language => 'javascript', :src => R(CStatic, 'js/prototype.js')
                # script :language => 'javascript', :src => R(CStatic, 'js/support.js')
                style "@import '#{self / R(CStatic, 'css/control.css')}';", :type => 'text/css'
            end
            body do
                div.page! do
                    if @user
                    div.menu do
                        ul do
                            li { a 'buckets', :href => R(CBuckets) }
                            li { a 'users',   :href => R(CUsers)   }
                            li { a 'profile', :href => R(CProfile) }
                            li { a 'logout',  :href => R(CLogout)  }
                        end
                    end
                    end
                    div.header! do
                        h1 "Park Place"
                        h2 str
                    end
                    div.content! do
                        __send__ "control_#{view}"
                    end
                end
            end
        end
    end

    def control_login
        control_loginform
    end

    def control_loginform
        form :action => R(CLogin), :method => 'post', :class => 'create' do
            errors_for @user if @user
            div.required do
                label 'User', :for => 'login'
                input.login! :type => 'text'
            end
            div.required do
                label 'Password', :for => 'password'
                input.password! :type => 'password'
            end
            input.loggo! :type => 'submit', :value => "Login"
        end
    end

    def control_buckets
        table :width => "100%" do
            thead do
                th "Name"
                th "Contains"
                th "Updated on"
                th "Permission"
            end
            tbody do
                @buckets.each do |bucket|
                    tr do
                        th { a bucket.name, :href => R(CFiles, bucket.name) }
                        td "#{bucket.children_count rescue 0} files"
                        td bucket.updated_at
                        td bucket.access_readable
                    end
                end
            end
        end
        form :action => R(CBuckets), :method => 'post', :class => 'create' do
            h3 "Create a Bucket"
            div.required do
                label 'Bucket Name', :for => 'bname'
                input :name => 'bname', :type => 'text'
            end
            div.required do
                label 'Permissions', :for => 'bacl'
                select :name => 'bacl' do
                    ParkPlace::CANNED_ACLS.sort.each do |acl, perm|
                        option acl, :value => perm
                    end
                end
            end
            input.newbucket! :type => 'submit', :value => "Create"
        end
    end

    def control_files
        table :width => "100%" do
            thead do
                th "File"
                th "Size"
                th "Updated on"
                th "Permission"
                th "Actions"
            end
            tbody do
                @files.each do |file|
                    tr do
                        th { a file.name, :href => R(CFile, @bucket.name, file.name) }
                        td number_to_human_size(file.obj.size)
                        td file.updated_at
                        td bucket.access_readable
                        td { a "Delete", :href => R(CFile, @bucket.name, file.name) }
                    end
                end
            end
        end
        form :action => R(CFiles, @bucket.name), :method => 'post', :enctype => 'multipart/form-data', :class => 'create' do
            h3 "Upload a File"
            div.required do
                input :name => 'upfile', :type => 'file'
            end
            div.optional do
                label 'File Name', :for => 'fname'
                input :name => 'fname', :type => 'text'
            end
            div.required do
                label 'Permissions', :for => 'facl'
                select :name => 'facl' do
                    ParkPlace::CANNED_ACLS.sort.each do |acl, perm|
                        option acl, :value => perm
                    end
                end
            end
            input.newfile! :type => 'submit', :value => "Create"
        end
    end

    def control_users
        table :width => "100%" do
            thead do
                th "Login"
                th "Created on"
            end
            tbody do
                @users.each do |user|
                    tr do
                        th { a user.login, :href => R(CUser, user.login) }
                        td user.created_at
                    end
                end
            end
        end
        form :action => R(CUsers), :method => 'post', :class => 'create' do
            h3 "Create a User"
            div.required do
                label 'Login', :for => 'login'
                input :name => 'login', :type => 'text'
            end
            input.newuser! :type => 'submit', :value => "Create"
        end
    end

    def control_profile
        form :action => R(CProfile), :method => 'post', :class => 'create' do
            div.required do
                label 'Login', :for => 'login'
                h4 @user.login
            end
            div.required do
                label 'Email', :for => 'email'
                input :name => 'email', :type => 'text', :value => @user.email
            end
            div.required do
                label 'Key', :for => 'key'
                h4 @user.key
            end
            div.required do
                label 'Secret', :for => 'secret'
                h4 @user.secret
            end
            input.newfile! :type => 'submit', :value => "Save"
            input.regen! :type => 'submit', :value => "Generate New Keys"
        end
    end

    def number_to_human_size(size)
      case 
        when size < 1.kilobyte: '%d Bytes' % size
        when size < 1.megabyte: '%.1f KB'  % (size / 1.0.kilobyte)
        when size < 1.gigabyte: '%.1f MB'  % (size / 1.0.megabyte)
        when size < 1.terabyte: '%.1f GB'  % (size / 1.0.gigabyte)
        else                    '%.1f TB'  % (size / 1.0.terabyte)
      end.sub('.0', '')
    rescue
      nil
    end
end
