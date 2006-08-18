require 'fileutils'

module ParkPlace
    module SlotGet
        def head(bucket_name, oid)
            @slot = ParkPlace::Models::Bucket.find_root(bucket_name).find_slot(oid)
            only_can_read @slot

            etag = @slot.etag
            since = Time.httpdate(@env.HTTP_IF_MODIFIED_SINCE) rescue nil
            raise NotModified if since and @slot.updated_at <= since
            since = Time.httpdate(@env.HTTP_IF_UNMODIFIED_SINCE) rescue nil
            raise PreconditionFailed if since and @slot.updated_at > since
            raise PreconditionFailed if @env.HTTP_IF_MATCH and etag != @env.HTTP_IF_MATCH
            raise NotModified if @env.HTTP_IF_NONE_MATCH and etag == @env.HTTP_IF_NONE_MATCH

            headers = {}
            if @slot.meta
                @slot.meta.each { |k, v| headers["x-amz-meta-#{k}"] = v }
            end
            if @slot.obj.is_a? ParkPlace::Models::FileInfo
                headers['Content-Type'] = @slot.obj.mime_type
                headers['Content-Disposition'] = @slot.obj.disposition
            end
            headers['Content-Type'] ||= 'binary/octet-stream'
            r(200, '', headers.merge('ETag' => etag, 'Last-Modified' => @slot.updated_at.httpdate, 'Content-Length' => @slot.obj.size))
        end
        def get(bucket_name, oid)
            head(bucket_name, oid)
            if @input.has_key? 'torrent'
                torrent @slot
            elsif @env.HTTP_RANGE  # ugh, parse ranges
                raise NotImplemented
            else
                case @slot.obj
                when ParkPlace::Models::FileInfo
                    file_path = File.join(STORAGE_PATH, @slot.obj.path)
                    headers['X-Sendfile'] = file_path
                else
                    @slot.obj
                end
            end
        end
    end

    module Controllers
        def self.S3 *routes
            R(*routes).send :include, ParkPlace::S3, Base
        end
    end
end
