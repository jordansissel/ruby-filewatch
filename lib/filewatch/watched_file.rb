require 'filewatch/boot_setup' unless defined?(FileWatch)

module FileWatch
  class WatchedFile
    def self.win_inode(path, stat)
      fileId = Winhelper.GetWindowsUniqueFileIdentifier(path)
      [fileId, 0, 0] # dev_* doesn't make sense on Windows
    end

    def self.nix_inode(path, stat)
      [stat.ino.to_s, stat.dev_major, stat.dev_minor]
    end

    def self.inode(path, stat)
      # removed the send(sym, ...) call
      # its slow and this is called on each restat
      if FILEWATCH_INODE_METHOD == :win_inode
        win_inode(path, stat)
      else
        nix_inode(path, stat)
      end
    end

    def self.new_initial(path, stat)
      new(path, stat, true).from_discover
    end

    def self.new_ongoing(path, stat)
      new(path, stat, false).from_discover
    end

    attr_reader :bytes_read, :inode, :state, :file, :buffer, :state_history
    attr_reader :path, :filestat, :accessed_at, :modified_at, :fingerprints
    attr_reader :sdb_key_v1, :storage_key, :last_stat_size
    attr_accessor :close_older, :ignore_older, :delimiter

    def delimiter
      @delimiter
    end

    # this class represents a file that has been discovered
    def initialize(path, stat, initial)
      @path = path
      @bytes_read = 0
      @last_stat_size = 0
      # we still need the inode
      # in case this points to an old sincedb record
      # and we only need it once
      @inode = self.class.inode(path, stat)
      @initial = initial
      @state_history = []
      @state = :watched
      @fingerprints = []
      set_stat(stat)
      @initial_stat_size = @last_stat_size
      set_fingerprints
      set_accessed_at
    end

    def init_vars(delim, ignore_o, close_o)
      @delimiter = delim
      @ignore_older = ignore_o
      @close_older = close_o
      self
    end

    def set_storage_keys
      @sdb_key_v1 = SincedbKey1.new(*@inode.map(&:to_i))
      @storage_key = SincedbKey2.new(*@fingerprints.first.to_a)
    end

    def first_fingerprint
      @fingerprints.first
    end

    def last_fingerprint
      return nil if @fingerprints.size < 2
      @fingerprints.last
    end

    # called when a direct key lookup using current storage_key failed
    # keys are a list of possible sdb keys with a length < FP_BYTE_SIZE
    # and offset should be zero
    # returns old_key and new_key
    def first_fingerprint_match_any?(keys)
      # fingerprinting might be defered if there is no content
      return [] if unstorable?
      matched = first_fingerprint.match_any?(keys)
      return [] if !matched
      [matched, storage_key]
    end

    def last_fingerprint_match?(fp_from_disk)
      return false if unstorable?
      dfp, doffset, dsize = fp_from_disk.to_a
      return false if @last_stat_size < (doffset + dsize)
      # is last_fingerprint usable?
      fp2 = last_fingerprint
      if fp2 && fp2.offset == doffset && fp2.size == dsize && fp2.fingerprint == dfp
        return true
      end
      new_fp = Fingerprinter.new(@path, doffset).read_path
      if dsize < FP_BYTE_SIZE
        new_fp.add_size(dsize)
      end
      if new_fp.fingerprint == dfp
        fp2.clear if fp2
        @fingerprints[1] = new_fp
        return true
      end
      false
    end

    def from_discover
      @discovered = true
      self
    end

    def from_sincedb
      @discovered = false
      self
    end

    def set_accessed_at
      @accessed_at = Time.now.to_f
    end

    def discovered?
      @discovered
    end

    def initial?
      @initial
    end

    def size_changed?
      @last_stat_size != bytes_read
    end

    def read_all?
      @last_stat_size == bytes_read
    end

    def open
      # if short_read?
      #   first_fingerprint.to_io
      # end
      file_add_opened(FileOpener.open(@path))
    end

    def file_add_opened(rubyfile)
      @file = rubyfile
      @buffer = BufferedTokenizer.new(delimiter || "\n") if @buffer.nil?
    end

    def file_close
      return if @file.nil? || @file.closed?
      @file.close
      @file = nil
    end

    def file_seek(amount, whence = IO::SEEK_SET)
      @file.sysseek(amount, whence)
    end

    def file_read(amount)
      set_accessed_at
      pos = @file.pos
      @file.sysread(amount).tap do |data|
        if pos >= FILE_READ_SIZE && data.size >= FP_BYTE_SIZE
          fp2 = last_fingerprint
          if fp2
            # if a fp2 was generated on a static file discover or one was read from disk
            # and its end position is less than where we are now
            # replace it.
            if fp2.end_position < (pos + FP_BYTE_SIZE)
              # STDERR.puts "--------********-------> replace dynamic fingerprint - pos: #{pos}"
              @fingerprints[1] = Fingerprinter.new(@path, pos).add_data(data.slice(0, FP_BYTE_SIZE))
            end
          else
            # STDERR.puts "--------********-------> add dynamic fingerprint"
            @fingerprints[1] = Fingerprinter.new(@path, pos).add_data(data.slice(0, FP_BYTE_SIZE))
          end
        end
      end
    end

    def file_open?
      !@file.nil? && !@file.closed?
    end

    def buffer_extract(data)
      @buffer.extract(data)
    end

    def increment_bytes_read(delta)
      return if delta.nil?
      @bytes_read += delta
    end

    def update_bytes_read(total_bytes_read)
      return if total_bytes_read.nil?
      @bytes_read = total_bytes_read
    end

    def update_path(_path)
      @path = _path
    end

    def update_stat(st)
      set_stat(st)
    end

    def activate
      set_state :active
    end

    def ignore
      set_state :ignored
      @bytes_read = @filestat.size
    end

    def close
      set_state :closed
    end

    def watch
      set_state :watched
    end

    def unwatch
      set_state :unwatched
    end

    def active?
      @state == :active
    end

    def ignored?
      @state == :ignored
    end

    def closed?
      @state == :closed
    end

    def watched?
      @state == :watched
    end

    def unwatched?
      @state == :unwatched
    end

    def expiry_close_enabled?
      !@close_older.nil?
    end

    def expiry_ignore_enabled?
      !@ignore_older.nil?
    end

    def unstorable?
      @fingerprints.empty?
    end

    def short_read?
      @short_read
    end

    def shrunk?
      @last_stat_size < @bytes_read
    end

    def grown?
      @last_stat_size > @bytes_read
    end

    def invalidate_fingerprints!
      if @last_stat_size.zero?
        @fingerprints.clear
        return true
      end
      if unstorable?
        # if it grew then it becomes storable
        # otherwise it stays unstorable in the sincedb
        set_fingerprints
        return true
      end
      fp1 = first_fingerprint
      new_fp = Fingerprinter.new(@path, 0).read_path
      # if we can't get a full fingerprint and
      # the new_fp has the same starting data as the old one;
      # or they are equal
      # don't replace it
      # (NOTE: this may be a problem with very small files)
      if fp1 == new_fp
        # STDERR.puts "-----------------------> fp valid - size: #{fp1.size}"
        return false
      end
      # we have a file with new content
      # or a longer fingerprint
      replace_first_fingerprint(new_fp)
      true
    end

    def restat
      set_stat(File::Stat.new(path))
    end

    def set_state(value)
      @state_history << @state
      @state = value
    end

    def state_history_any?(*previous)
      (@state_history & previous).any?
    end

    def file_closable?
      file_can_close? && read_all?
    end

    def file_ignorable?
      return false unless expiry_ignore_enabled?
      # (Time.now - stat.mtime) <- in jruby, this does int and float
      # conversions before the subtraction and returns a float.
      # so use all floats upfront
      (Time.now.to_f - @modified_at) > ignore_older
    end

    def file_can_close?
      return false unless expiry_close_enabled?
      (Time.now.to_f - @accessed_at) > close_older
    end

    def to_s() inspect; end

    private

    def replace_first_fingerprint(fp)
      @fingerprints[0] = fp
      # set_last_fingerprint
      set_storage_keys
    end

    def set_last_fingerprint
      offset = compute_last_fp_offset
      if offset > 0
        @fingerprints[1] = Fingerprinter.new(@path, offset).read_path
      end
    end

    def set_fingerprints
      # if a new truncated file is discovered before content is added
      # defer the fingerprinting till later
      return if @last_stat_size == 0
      @fingerprints.clear
      begin
        targetfile = FileOpener.open(@path)
        [0, compute_last_fp_offset].uniq.each do |offset|
          @fingerprints << Fingerprinter.new(@path, offset).read_file(targetfile)
        end
        set_storage_keys
      rescue => e
        # most likely caused when file has gone away
        # STDERR.puts "A rescued error occurred in WatchedFile set_fingerprints"
      ensure
        targetfile.close if !targetfile.nil?
      end
    end

    def compute_last_fp_offset
      return 0 if @last_stat_size < FP_BYTE_SIZE
      return 0 if @read_blocks == 0
      # the second fingerprint that we take here is more useful in the read complete file case
      @read_blocks * FILE_READ_SIZE
    end

    def set_stat(stat)
      size = stat.size
      @short_read = size > 0 && size < FP_BYTE_SIZE
      @modified_at = stat.mtime.to_f
      if size > @last_stat_size || size < @last_stat_size
        @read_blocks, @last_read_block_size = size.divmod(FILE_READ_SIZE)
      end
      @last_stat_size = size
      @filestat = stat
    end
  end
end
