require 'rubytorrent'

class String
    def to_hex_s
        unpack("H*").first
    end
    def from_hex_s
        [self].pack("H*")
    end
end

module ParkPlace
    # TORRENT_SERVER = RubyTorrent::Server.new("192.168.0.4", 3003).start
    TRACKER_INTERVAL = 10.minutes

    # All tracker errors are thrown as this class.
    class TrackerError < Exception; end

    def torrent bit
        mi = bit.metainfo
        mi.announce = URL(Controllers::CTracker)
        mi.created_by = "Served by ParkPlace/#{ParkPlace::VERSION}"
        mi.creation_date = Time.now
        t = Models::Torrent.find_by_bit_id bit.id
        info_hash = Digest::SHA1.digest(mi.info.to_bencoding).to_hex_s
        unless t and t.info_hash == info_hash
            t ||= Models::Torrent.new
            t.update_attributes(:info_hash => info_hash, :bit_id => bit.id, :metainfo => "X!X NOT CACHED X!X")
        end
        # unless TORRENT_SERVER.instance_variable_get("@controllers").has_key? mi.info.sha1
        #     begin
        #         puts "SEEDING..."
        #         p TORRENT_SERVER.add_torrent(mi, RubyTorrent::Package.new(mi, bit.fullpath))
        #     rescue Exception => e
        #         puts "#{e.class}: #{e.message}"
        #     end
        # end
        r(200, mi.to_bencoding, 'Content-Disposition' => "attachment; filename=#{bit.name}.torrent;",
            'Content-Type' => 'application/x-bittorrent')
    end

    def torrent_list(info_hash)
        params = {:order => 'seeders DESC, leechers DESC', :include => :bit}
        if info_hash
            params[:conditions] = ['info_hash = ?', info_hash]
        end
        Models::Torrent.find :all, params
    end

    def tracker_reply(params)
        r(200, params.merge('interval' => TRACKER_INTERVAL).to_bencoding, 'Content-Type' => 'text/plain')
    end

    def tracker_error msg
        r(200, {'failure reason' => msg}.to_bencoding, 'Content-Type' => 'text/plain')
    end
end

module ParkPlace::Models
    class Bit
        def each_piece(files, length)
           buf = ""
           files.each do |f|
               File.open(f) do |fh|
                   begin
                       read = fh.read(length - buf.length)
                       if (buf.length + read.length) == length
                           yield(buf + read)
                           buf = ""
                       else
                           buf += read
                       end
                   end until fh.eof?
               end
           end

           yield buf
        end
    end

    class Bucket
        def metainfo
            children = self.all_children
            mii = RubyTorrent::MetaInfoInfo.new
            mii.name = self.name
            mii.piece_length = 512.kilobytes
            mii.files, files = [], []
            mii.pieces = ""
            i = 0
            Slot.find(:all, :conditions => ['parent_id = ?', self.id]).each do |slot|
                miif = RubyTorrent::MetaInfoInfoFile.new
                miif.length = slot.obj.size
                miif.md5sum = slot.obj.md5
                miif.path = File.split(slot.name)
                mii.files << miif
                files << slot.fullpath
            end
            each_piece(files, mii.piece_length) do |piece|
                mii.pieces += Digest::SHA1.digest(piece)
                i += 1
            end
            mi = RubyTorrent::MetaInfo.new
            mi.info = mii
            mi
        end
    end

    class Slot
        def metainfo
            mii = RubyTorrent::MetaInfoInfo.new
            mii.name = self.name
            mii.length = self.obj.size
            mii.md5sum = self.obj.md5
            mii.piece_length = 512.kilobytes
            mii.pieces = ""
            i = 0
            each_piece([self.fullpath], mii.piece_length) do |piece|
                mii.pieces += Digest::SHA1.digest(piece)
                i += 1
            end
            mi = RubyTorrent::MetaInfo.new
            mi.info = mii
            mi
        end
    end
end

module ParkPlace::Controllers
    class CTracker < R '/tracker/announce'
        EVENT_CODES = {
            'started' => 200, 
            'completed' => 201, 
            'stopped' => 202
        }
        def get
            raise ParkPlace::TrackerError, "No info_hash present." unless @input.info_hash
            raise ParkPlace::TrackerError, "No peer_id present." unless @input.peer_id

            # p @input
            info_hash = @input.info_hash.to_hex_s
            guid = @input.peer_id.to_hex_s
            trnt = Torrent.find_by_info_hash(info_hash)
            raise ParkPlace::TrackerError, "No file found with hash of `#{@input.info_hash}'." unless trnt

            peer = TorrentPeer.find_by_guid_and_torrent_id(guid, trnt.id)
            unless peer
                peer = TorrentPeer.find_by_ipaddr_and_port_and_torrent_id(@env.REMOTE_ADDR, @input.port, trnt.id)
            end
            unless peer
                peer = TorrentPeer.new(:torrent_id => trnt.id)
                trnt.hits += 1
            end

            if @input.event == 'completed'
                trnt.total += 1
            end
            @input.event = 'completed' if @input.left == "0"
            peer.update_attributes(:port => @input.port, :uploaded => @input.uploaded, :downloaded => @input.downloaded,
                                   :remaining => @input.left, :event => EVENT_CODES[@input.event], :key => @input.key,
                                   :ipaddr => @env.REMOTE_ADDR, :guid => guid)
            complete, incomplete = 0, 0
            peers = trnt.torrent_peers.map do |peer|
                if peer.updated_at < Time.now - (TRACKER_INTERVAL * 2) or (@input.event == 'stopped' and peer.guid == guid)
                    peer.destroy
                    next
                end
                if peer.event == EVENT_CODES['completed']
                    complete += 1
                else
                    incomplete += 1
                end
                next if peer.guid == guid
                {'peer id' => peer.guid.from_hex_s, 'ip' => peer.ipaddr, 'port' => peer.port}
            end.compact
            trnt.seeders = complete
            trnt.leechers = incomplete
            trnt.save
            tracker_reply('peers' => peers, 'complete' => complete, 'incomplete' => incomplete)
        rescue Exception => e
            puts "#{e.class}: #{e.message}"
            tracker_error "#{e.class}: #{e.message}"
        end
    end

    class CTrackerScrape < R '/tracker/scrape'
        def get
            torrents = torrent_list @input.info_hash
            tracker_reply('files' => torrents.map { |t| 
                {'complete' => t.seeders, 'downloaded' => t.total, 'incomplete' => t.leechers, 'name' => t.bit.name} })
        end
    end

    class CTrackerIndex < R '/tracker'
        def get
            @torrents = torrent_list @input.info_hash
            render :torrent_index
        end
    end
end

module ParkPlace::Views
    def torrent_index
        html do
            head do
                title "Park Place Torrents"
            end
            body do
                table do
                    thead do
                        tr do
                        th "Name"
                        th "Seeders"
                        th "Leechers"
                        th "Downloads"
                        end
                    end
                    tbody do
                    torrents.each do |t|
                        tr do  
                            td t.bit.name
                            td t.seeders
                            td t.leechers
                            td t.total
                        end
                    end
                    end
                end
            end
        end
    end
end
