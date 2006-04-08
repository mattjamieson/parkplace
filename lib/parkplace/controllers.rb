module ParkPlace
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
end
